import Foundation

public enum ExportServiceError: Error, Equatable, Sendable {
    case pdfWorkerUnavailable
    case selectorNotFound
    case pdfSourceUnavailable
    case pdfReadFailed
}

struct ExportService {
    let annotationQueries: AnnotationQueries?
    let bookQueries: BookQueries
    let configuration: AppleBooksConfiguration?
    let pdfService: PDFHighlightService?
    var pdfSourceResolver: PDFSourceResolver = PDFSourceResolver()

    func makeBundle(options: ExportOptions) throws -> ExportBundle {
        let resolver = ExportSourceResolver(
            bookQueries: bookQueries,
            pdfSourceResolver: pdfService?.sourceResolver ?? pdfSourceResolver
        )
        let resolvedSelectors = try resolver.resolve(options.bookSelectors)

        var records: [ExportRecord] = []
        var warnings: [ExportWarning] = []

        if options.source != .pdf {
            let annotations = try epubAnnotations(options: options, resolvedSelectors: resolvedSelectors)
            records.append(contentsOf: annotations.map { ExportRecord(payload: .epub($0)) })
        }

        var pdfResult: PDFHighlightServiceResult?
        let exactPDFSources = resolvedSelectors.compactMap(\.pdfSource)
        let readsPDF = options.bookSelectors.isEmpty ? options.source != .epub : !exactPDFSources.isEmpty
        if readsPDF {
            do {
                guard let pdfService else { throw ExportServiceError.pdfWorkerUnavailable }
                let sources = try options.bookSelectors.isEmpty ? pdfService.inventory() : exactPDFSources
                let result = pdfService.readHighlights(sources: sources)
                if !options.bookSelectors.isEmpty, result.failedCount > 0 {
                    throw ExportServiceError.pdfReadFailed
                }
                pdfResult = result
                warnings.append(contentsOf: result.failures.map(ExportWarning.pdfFailure))
                for document in result.documents {
                    records.append(contentsOf: document.highlights.map {
                        ExportRecord(payload: .pdf(source: document.source, highlight: $0))
                    })
                }
            } catch {
                guard options.bookSelectors.isEmpty, options.source == .all else { throw error }
                warnings.append(.pdfUnavailable)
            }
        }

        let sourceClassified = records.filter { $0.isKnownCurrentPDFAnnotation == false }
        let sourceTotals = makeSourceTotals(records: sourceClassified, pdfResult: pdfResult)
        let selected = try ExportSelection.apply(options: options, to: sourceClassified) { record in
            guard case let .epub(enriched) = record.payload,
                  case let .currentLibrary(book) = enriched.source else { return [:] }
            return try annotationQueries?.resolveReadingContext(bookLocalPK: book.localPK).chapterOrder ?? [:]
        }
        var groups = makeGroups(records: selected)

        if options.includeEPUBMetadata || options.cover != .none {
            for index in groups.indices {
                let result = try enrich(group: groups[index], options: options)
                groups[index] = result.group
                warnings.append(contentsOf: result.warnings)
            }
        }

        return ExportBundle(
            options: options,
            groups: groups,
            warnings: warnings,
            statistics: makeStatistics(groups: groups),
            sourceTotals: sourceTotals
        )
    }

    private func epubAnnotations(
        options: ExportOptions,
        resolvedSelectors: [ResolvedExportSource]
    ) throws -> [EnrichedAnnotation] {
        if options.bookSelectors.isEmpty {
            guard let annotationQueries else { throw AppleBooksDependencyError.unavailable(.annotationsRead) }
            return try annotationQueries.list(scope: .user)
        }
        let epubSources = resolvedSelectors.filter { $0.pdfSource == nil }
        guard !epubSources.isEmpty else { return [] }
        guard let annotationQueries else { throw AppleBooksDependencyError.unavailable(.annotationsRead) }

        var annotations: [EnrichedAnnotation] = []
        for source in epubSources {
            guard let assetID = source.epubAssetID else { continue }
            let selected = try annotationQueries.byAssetID(assetID, scope: .user)
            if source.requiresHistoricalEvidence,
               selected.isEmpty,
               annotationQueries.historicalAssets.metadata(for: assetID) == nil {
                throw ExportServiceError.selectorNotFound
            }
            annotations.append(contentsOf: selected)
        }
        return annotations
    }

    private func makeGroups(records: [ExportRecord]) -> [ExportGroup] {
        var order: [ExportDocumentKey] = []
        var grouped: [ExportDocumentKey: [ExportRecord]] = [:]
        for record in records {
            if grouped[record.documentKey] == nil { order.append(record.documentKey) }
            grouped[record.documentKey, default: []].append(record)
        }
        return order.compactMap { key in
            guard let records = grouped[key], let first = records.first else { return nil }
            return ExportGroup(source: groupSource(record: first), records: records)
        }
    }

    private func groupSource(record: ExportRecord) -> ExportGroupSource {
        switch record.payload {
        case let .epub(enriched):
            switch enriched.source {
            case let .currentLibrary(book):
                return .epubCurrent(book)
            case let .historicalInferred(metadata):
                return .epubHistorical(
                    assetID: enriched.annotation.rawAssetID,
                    metadata: metadata
                )
            case .unmapped:
                return .epubUnmapped(assetID: enriched.annotation.rawAssetID)
            }
        case let .pdf(source, _):
            return .pdf(source)
        }
    }

    private func enrich(
        group: ExportGroup,
        options: ExportOptions
    ) throws -> (group: ExportGroup, warnings: [ExportWarning]) {
        guard case let .epubCurrent(book) = group.source else { return (group, []) }
        guard let configuration else { throw AppleBooksDependencyError.unavailable(.configuration) }

        let content: BookContent
        do {
            content = try BookContent(reader: EPUBSourceResolver.reader(for: book, configuration: configuration))
        } catch {
            return (
                group,
                [.epubContentUnavailable(bookLocalPK: book.localPK)]
            )
        }

        var metadata: EPUBMetadata?
        var cover: EPUBCover?
        var warnings: [ExportWarning] = []

        if options.includeEPUBMetadata {
            do {
                metadata = try content.metadata()
            } catch {
                warnings.append(.epubMetadataUnavailable(bookLocalPK: book.localPK))
            }
        }
        if options.cover != .none {
            do {
                cover = try content.cover()
            } catch {
                warnings.append(.epubCoverUnavailable(bookLocalPK: book.localPK))
            }
        }

        return (
            ExportGroup(
                source: group.source,
                records: group.records,
                epubMetadata: metadata,
                epubCover: cover
            ),
            warnings
        )
    }

    private func makeSourceTotals(
        records: [ExportRecord],
        pdfResult: PDFHighlightServiceResult?
    ) -> ExportSourceTotals {
        let epubRecords = records.filter {
            if case .epub = $0.payload { return true }
            return false
        }
        let epubDocuments = Set(epubRecords.map(\.documentKey)).count
        let pdfHighlights = records.count {
            if case .pdf = $0.payload { return true }
            return false
        }
        return ExportSourceTotals(
            epubDocumentCount: epubDocuments,
            epubAnnotationCount: epubRecords.count,
            pdfAttemptedDocumentCount: pdfResult?.attemptedCount ?? 0,
            pdfSucceededDocumentCount: pdfResult?.succeededCount ?? 0,
            pdfFailedDocumentCount: pdfResult?.failedCount ?? 0,
            pdfHighlightCount: pdfHighlights
        )
    }

    private func makeStatistics(groups: [ExportGroup]) -> ExportStatistics {
        var epubDocuments = 0
        var pdfDocuments = 0
        var epubAnnotations = 0
        var pdfHighlights = 0
        var highlights = 0
        var notes = 0
        var historical = 0
        var unmapped = 0

        for group in groups {
            switch group.source {
            case .epubCurrent:
                epubDocuments += 1
                epubAnnotations += group.records.count
            case .epubHistorical:
                epubDocuments += 1
                epubAnnotations += group.records.count
                historical += group.records.count
            case .epubUnmapped:
                epubDocuments += 1
                epubAnnotations += group.records.count
                unmapped += group.records.count
            case .pdf:
                pdfDocuments += 1
                pdfHighlights += group.records.count
            }

            for record in group.records {
                if record.hasHighlight { highlights += 1 }
                if record.hasNote { notes += 1 }
            }
        }

        return ExportStatistics(
            documentCount: groups.count,
            epubDocumentCount: epubDocuments,
            pdfDocumentCount: pdfDocuments,
            recordCount: epubAnnotations + pdfHighlights,
            epubAnnotationCount: epubAnnotations,
            pdfHighlightCount: pdfHighlights,
            highlightCount: highlights,
            noteCount: notes,
            historicalEPUBAnnotationCount: historical,
            unmappedEPUBAnnotationCount: unmapped
        )
    }
}

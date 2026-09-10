import Foundation

public enum ExportServiceError: Error, Equatable, Sendable {
    case pdfWorkerUnavailable
    case selectorNotFound
    case pdfSourceUnavailable
    case pdfReadFailed
    case documentIdentityCollision
}

struct ExportService {
    let annotationQueries: AnnotationQueries?
    let bookQueries: BookQueries
    let configuration: AppleBooksConfiguration?
    let pdfService: PDFHighlightService?
    var pdfSourceResolver: PDFSourceResolver = PDFSourceResolver()
    var documentIdentityDigest: (ResolvedExportSourceKey) throws -> [UInt8] = {
        try ExportDocumentIdentity.defaultDigest(for: $0)
    }

    func makeBundle(options: ExportOptions) throws -> ExportBundle {
        let resolver = ExportSourceResolver(
            bookQueries: bookQueries,
            pdfSourceResolver: pdfSourceResolver
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
                let sources = try options.bookSelectors.isEmpty
                    ? pdfSourceResolver.exportInventory(bookQueries: bookQueries)
                    : exactPDFSources
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
        let sourceTotals = try makeSourceTotals(records: sourceClassified, pdfResult: pdfResult)
        let selected = try ExportSelection.apply(options: options, to: sourceClassified) { record in
            guard case let .epub(enriched) = record.payload,
                  case let .currentLibrary(book) = enriched.source else { return [:] }
            return try annotationQueries?.resolveReadingContext(bookLocalPK: book.localPK).chapterOrder ?? [:]
        }
        let groups = try makeGroups(records: selected)

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
            return try annotationQueries.exportAnnotations()
        }
        let epubSources = resolvedSelectors.filter { $0.pdfSource == nil }
        guard !epubSources.isEmpty else { return [] }
        guard let annotationQueries else { throw AppleBooksDependencyError.unavailable(.annotationsRead) }

        var annotations: [EnrichedAnnotation] = []
        for source in epubSources {
            guard let assetID = source.epubAssetID else { continue }
            let selected = try annotationQueries.exportAnnotations(assetID: assetID)
            if source.requiresHistoricalEvidence,
               selected.isEmpty,
               annotationQueries.historicalAssets.metadata(for: assetID) == nil {
                throw ExportServiceError.selectorNotFound
            }
            annotations.append(contentsOf: selected)
        }
        return annotations
    }

    private func makeGroups(records: [ExportRecord]) throws -> [ExportGroup] {
        var grouped: [ResolvedExportSourceKey: [ExportRecord]] = [:]
        for record in records {
            grouped[try record.documentSourceKey, default: []].append(record)
        }

        var prepared: [(sourceKey: ResolvedExportSourceKey, group: ExportGroup)] = []
        prepared.reserveCapacity(grouped.count)
        for (sourceKey, records) in grouped {
            guard let first = records.first else { continue }
            let identity = try ExportDocumentIdentity.make(
                sourceKey: sourceKey,
                digest: documentIdentityDigest
            )
            prepared.append((
                sourceKey,
                ExportGroup(
                    source: groupSource(record: first),
                    records: records,
                    documentIdentity: identity
                )
            ))
        }
        prepared.sort { $0.group.documentIdentity! < $1.group.documentIdentity! }
        for index in prepared.indices.dropFirst() {
            let previous = prepared[prepared.index(before: index)]
            let current = prepared[index]
            if previous.group.documentIdentity == current.group.documentIdentity,
               previous.sourceKey != current.sourceKey {
                throw ExportServiceError.documentIdentityCollision
            }
        }
        return prepared.map(\.group)
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

    private func makeSourceTotals(
        records: [ExportRecord],
        pdfResult: PDFHighlightServiceResult?
    ) throws -> ExportSourceTotals {
        let epubRecords = records.filter {
            if case .epub = $0.payload { return true }
            return false
        }
        var epubDocumentKeys = Set<ResolvedExportSourceKey>()
        for record in epubRecords {
            epubDocumentKeys.insert(try record.documentSourceKey)
        }
        let epubDocuments = epubDocumentKeys.count
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

import Foundation

public enum ExportServiceError: Error, Equatable, Sendable {
    case pdfWorkerUnavailable
}

struct ExportService {
    let annotationQueries: AnnotationQueries
    let bookQueries: BookQueries
    let configuration: AppleBooksConfiguration
    let pdfService: PDFHighlightService?

    func makeBundle(options: ExportOptions) throws -> ExportBundle {
        let assetSelectors = uniqueAssetSelectors(options.bookSelectors)
        for assetID in assetSelectors {
            _ = try bookQueries.getUniqueByAssetID(assetID)
        }

        var records: [ExportRecord] = []
        var warnings: [ExportWarning] = []

        if options.source != .pdf {
            let annotations = try epubAnnotations(options: options, assetSelectors: assetSelectors)
            records.append(contentsOf: annotations.map { ExportRecord(payload: .epub($0)) })
        }

        var pdfResult: PDFHighlightServiceResult?
        if options.source != .epub {
            guard let pdfService else { throw ExportServiceError.pdfWorkerUnavailable }
            let sources = try selectedPDFSources(
                service: pdfService,
                selectors: options.bookSelectors
            )
            let result = pdfService.readHighlights(sources: sources)
            pdfResult = result
            warnings.append(contentsOf: result.failures.map(ExportWarning.pdfFailure))
            for document in result.documents {
                records.append(contentsOf: document.highlights.map {
                    ExportRecord(payload: .pdf(source: document.source, highlight: $0))
                })
            }
        }

        let sourceClassified = records.filter { $0.isKnownCurrentPDFAnnotation == false }
        let sourceTotals = makeSourceTotals(records: sourceClassified, pdfResult: pdfResult)
        let selected = ExportSelection.apply(options: options, to: sourceClassified)
        var groups = makeGroups(records: selected)

        if options.includeEPUBMetadata || options.cover != .none {
            for index in groups.indices {
                let result = enrich(group: groups[index], options: options)
                groups[index] = result.group
                warnings.append(contentsOf: result.warnings)
            }
        }

        let bundle = ExportBundle(
            options: options,
            groups: groups,
            warnings: warnings,
            statistics: makeStatistics(groups: groups),
            sourceTotals: sourceTotals
        )
        if ExportSafetyValidator.requiresCompleteNoteArchiveValidation(options) {
            let rawTotals = try annotationQueries.completeNoteArchiveRawTotals()
            try ExportSafetyValidator.validateDataset(bundle, rawTotals: rawTotals)
        }
        return bundle
    }

    private func epubAnnotations(
        options: ExportOptions,
        assetSelectors: [String]
    ) throws -> [EnrichedAnnotation] {
        guard options.bookSelectors.isEmpty == false else {
            return try annotationQueries.list(scope: .activeRaw)
        }
        guard assetSelectors.isEmpty == false else { return [] }

        var annotations: [EnrichedAnnotation] = []
        for assetID in assetSelectors {
            annotations.append(contentsOf: try annotationQueries.byAssetID(assetID, scope: .activeRaw))
        }
        return annotations
    }

    private func selectedPDFSources(
        service: PDFHighlightService,
        selectors: [ExportBookSelector]
    ) throws -> [PDFSource] {
        let sources = try service.inventory()
        guard selectors.isEmpty == false else { return sources }
        return sources.filter { source in
            selectors.contains { selector in
                switch selector {
                case let .assetID(assetID):
                    return source.book?.assetID == assetID
                case let .pdfFile(url):
                    return source.fileURL == url
                }
            }
        }
    }

    private func uniqueAssetSelectors(_ selectors: [ExportBookSelector]) -> [String] {
        var seen = Set<String>()
        return selectors.compactMap { selector in
            guard case let .assetID(assetID) = selector,
                  seen.insert(assetID).inserted else {
                return nil
            }
            return assetID
        }
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
    ) -> (group: ExportGroup, warnings: [ExportWarning]) {
        guard case let .epubCurrent(book) = group.source else { return (group, []) }

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
        var bookmarks = 0
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
                switch record.presentationKind {
                case .highlight: highlights += 1
                case .note: notes += 1
                case .bookmark: bookmarks += 1
                }
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
            bookmarkCount: bookmarks,
            historicalEPUBAnnotationCount: historical,
            unmappedEPUBAnnotationCount: unmapped
        )
    }
}

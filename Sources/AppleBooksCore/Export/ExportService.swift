import Foundation

public enum ExportServiceError: Error, Equatable, Sendable {
    case selectorNotFound
    case unsupportedBookFormat
    case documentIdentityCollision
}

struct ExportService {
    let annotationQueries: AnnotationQueries?
    let bookQueries: BookQueries
    var documentIdentityDigest: (ResolvedExportSourceKey) throws -> [UInt8] = {
        try ExportDocumentIdentity.defaultDigest(for: $0)
    }

    func makeBundle(options: ExportOptions) throws -> ExportBundle {
        let resolvedSelectors = try ExportSourceResolver(bookQueries: bookQueries)
            .resolve(options.bookSelectors)
        let annotations = try epubAnnotations(options: options, resolvedSelectors: resolvedSelectors)
        let records = annotations.map(ExportRecord.init(annotation:)).filter(\.isCurrentEPUBSource)
        let sourceTotals = makeSourceTotals(records: records)
        let selected = try ExportSelection.apply(options: options, to: records) { record in
            guard case let .currentLibrary(book) = record.annotation.source else { return [:] }
            return try annotationQueries?.resolveReadingContext(bookLocalPK: book.localPK).chapterOrder ?? [:]
        }
        let groups = try makeGroups(records: selected)

        return ExportBundle(
            options: options,
            groups: groups,
            statistics: makeStatistics(groups: groups),
            sourceTotals: sourceTotals
        )
    }

    private func epubAnnotations(
        options: ExportOptions,
        resolvedSelectors: [ResolvedExportSource]
    ) throws -> [EnrichedAnnotation] {
        guard let annotationQueries else {
            throw AppleBooksDependencyError.unavailable(.annotationsRead)
        }
        if options.bookSelectors.isEmpty {
            return try annotationQueries.exportAnnotations()
        }

        var annotations: [EnrichedAnnotation] = []
        for source in resolvedSelectors {
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
            grouped[record.documentSourceKey, default: []].append(record)
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
        switch record.annotation.source {
        case let .currentLibrary(book):
            return .epubCurrent(book)
        case let .historicalInferred(metadata):
            return .epubHistorical(
                assetID: record.annotation.annotation.rawAssetID,
                metadata: metadata
            )
        case .unmapped:
            return .epubUnmapped(assetID: record.annotation.annotation.rawAssetID)
        }
    }

    private func makeSourceTotals(records: [ExportRecord]) -> ExportSourceTotals {
        let documentKeys = Set(records.map(\.documentSourceKey))
        return ExportSourceTotals(
            epubDocumentCount: documentKeys.count,
            epubAnnotationCount: records.count
        )
    }

    private func makeStatistics(groups: [ExportGroup]) -> ExportStatistics {
        var historical = 0
        var unmapped = 0
        var highlights = 0
        var notes = 0
        var recordCount = 0

        for group in groups {
            recordCount += group.records.count
            switch group.source {
            case .epubCurrent: break
            case .epubHistorical: historical += group.records.count
            case .epubUnmapped: unmapped += group.records.count
            }
            for record in group.records {
                if record.hasHighlight { highlights += 1 }
                if record.hasNote { notes += 1 }
            }
        }

        return ExportStatistics(
            documentCount: groups.count,
            epubDocumentCount: groups.count,
            recordCount: recordCount,
            epubAnnotationCount: recordCount,
            highlightCount: highlights,
            noteCount: notes,
            historicalEPUBAnnotationCount: historical,
            unmappedEPUBAnnotationCount: unmapped
        )
    }
}

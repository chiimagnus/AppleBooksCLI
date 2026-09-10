import Foundation

public enum ExportRecordPayload: Equatable, Sendable {
    case epub(EnrichedAnnotation)
    case pdf(source: PDFSource, highlight: PDFHighlight)
}

public struct ExportRecord: Equatable, Sendable {
    public let payload: ExportRecordPayload

    init(payload: ExportRecordPayload) {
        self.payload = payload
    }

    var hasHighlight: Bool {
        switch payload {
        case let .epub(enriched):
            AnnotationContentSemantics.hasContent(enriched.annotation.selectedText)
        case .pdf:
            true
        }
    }

    var hasNote: Bool {
        switch payload {
        case let .epub(enriched):
            AnnotationContentSemantics.hasContent(enriched.annotation.note)
        case let .pdf(_, highlight):
            AnnotationContentSemantics.hasContent(highlight.note)
        }
    }

    var semanticColor: ExportPresentationColor? {
        guard case .epub = payload else { return nil }
        return presentationColor
    }

    var presentationColor: ExportPresentationColor? {
        switch payload {
        case let .epub(enriched):
            switch enriched.annotation.style {
            case 1: .green
            case 2: .blue
            case 3: .yellow
            case 4: .pink
            case 5: .purple
            default: nil
            }
        case let .pdf(_, highlight):
            highlight.presentationColor.flatMap { ExportPresentationColor(rawValue: $0.color.rawValue) }
        }
    }

    var isUnderline: Bool {
        switch payload {
        case let .epub(enriched): enriched.annotation.isUnderline == true
        case .pdf: false
        }
    }

    var documentKey: ExportDocumentKey {
        switch payload {
        case let .epub(enriched):
            if let assetID = enriched.annotation.rawAssetID {
                return .epubAsset(assetID)
            }
            return .epubLocalPK(enriched.annotation.localPK)
        case let .pdf(source, _):
            return .pdfPath(source.fileURL.path)
        }
    }

    var isKnownCurrentPDFAnnotation: Bool {
        guard case let .epub(enriched) = payload,
              case let .currentLibrary(book) = enriched.source else {
            return false
        }
        return book.contentType == 3
    }

    fileprivate func readingKey(chapterOrder: [String: Int]) -> ReadingKey {
        switch payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            return .epub(EPUBAnnotationReadingKey.make(
                rawCFI: annotation.location?.rawCFI,
                chapterOrder: chapterOrder,
                createdAt: annotation.createdAt,
                localPK: annotation.localPK
            ))
        case let .pdf(_, highlight):
            return .pdf(
                page: highlight.page,
                maxY: Double(highlight.bounds.maxY),
                minX: Double(highlight.bounds.minX),
                traversalIndex: highlight.traversalIndex
            )
        }
    }

}

enum ExportSelection {
    static func apply(
        options: ExportOptions,
        to records: [ExportRecord],
        chapterOrder: (ExportRecord) throws -> [String: Int] = { _ in [:] }
    ) rethrows -> [ExportRecord] {
        let filtered = records.enumerated().compactMap { index, record -> IndexedRecord? in
            guard sourceAllows(options.source, record),
                  record.isKnownCurrentPDFAnnotation == false,
                  record.hasHighlight || record.hasNote,
                  options.hasHighlight.map({ $0 == record.hasHighlight }) ?? true,
                  options.hasNote.map({ $0 == record.hasNote }) ?? true,
                  options.colors.map({ colors in record.semanticColor.map(colors.contains) == true }) ?? true,
                  options.underline.map({ $0 == record.isUnderline }) ?? true else {
                return nil
            }
            return IndexedRecord(index: index, record: record)
        }

        var groupOrder: [ExportDocumentKey] = []
        var groups: [ExportDocumentKey: [IndexedRecord]] = [:]
        for item in filtered {
            let key = item.record.documentKey
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(item)
        }
        return try groupOrder.flatMap { key -> [ExportRecord] in
            guard let group = groups[key], let first = group.first else { return [] }
            let chapters = try chapterOrder(first.record)
            let sorted = group.map {
                ReadingRecord(index: $0.index, record: $0.record, key: $0.record.readingKey(chapterOrder: chapters))
            }.sorted(by: readingOrder)
            return sorted.map(\.record)
        }
    }

    private static func sourceAllows(_ scope: ExportSourceScope, _ record: ExportRecord) -> Bool {
        switch (scope, record.payload) {
        case (.all, _), (.epub, .epub), (.pdf, .pdf): true
        default: false
        }
    }

    private static func readingOrder(_ lhs: ReadingRecord, _ rhs: ReadingRecord) -> Bool {
        switch (lhs.key, rhs.key) {
        case let (.epub(left), .epub(right)):
            return EPUBAnnotationReadingKey.lessThan(left, right)
        case let (.pdf(lp, ly, lx, li), .pdf(rp, ry, rx, ri)):
            if lp != rp { return lp < rp }
            if ly != ry { return ly > ry }
            if lx != rx { return lx < rx }
            if li != ri { return li < ri }
            return lhs.index < rhs.index
        default:
            return lhs.index < rhs.index
        }
    }

}

private struct IndexedRecord {
    let index: Int
    let record: ExportRecord
}

private struct ReadingRecord {
    let index: Int
    let record: ExportRecord
    let key: ReadingKey
}

enum ExportDocumentKey: Hashable, Sendable {
    case epubAsset(String)
    case epubLocalPK(Int64)
    case pdfPath(String)
}

private enum ReadingKey {
    case epub(EPUBAnnotationReadingKey)
    case pdf(page: Int, maxY: Double, minX: Double, traversalIndex: Int)
}

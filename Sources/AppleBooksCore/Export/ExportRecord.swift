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

    var presentationKind: ExportPresentationKind {
        switch payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let note = annotation.note,
               note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return .note
            }
            guard let selected = annotation.selectedText, selected.isEmpty == false else {
                return .bookmark
            }
            return .highlight
        case let .pdf(_, highlight):
            if let note = highlight.note,
               note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return .note
            }
            return .highlight
        }
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

    fileprivate func matches(_ selector: ExportBookSelector) -> Bool {
        switch (payload, selector) {
        case let (.epub(enriched), .assetID(assetID)):
            return enriched.annotation.rawAssetID == assetID
        case let (.pdf(source, _), .assetID(assetID)):
            return source.book?.assetID == assetID
        case let (.epub(enriched), .localPK(localPK)):
            guard case let .currentLibrary(book) = enriched.source else { return false }
            return book.localPK == localPK
        case let (.pdf(source, _), .localPK(localPK)):
            return source.book?.localPK == localPK
        case let (.pdf(source, _), .pdfFile(url)):
            return source.fileURL == url
        case (.epub, .pdfFile):
            return false
        }
    }

    fileprivate var readingKey: ReadingKey {
        switch payload {
        case let .epub(enriched):
            return .epub(Self.cfiNumbers(enriched.annotation.location?.rawCFI))
        case let .pdf(_, highlight):
            return .pdf(
                page: highlight.page,
                maxY: Double(highlight.bounds.maxY),
                minX: Double(highlight.bounds.minX),
                traversalIndex: highlight.traversalIndex
            )
        }
    }

    private static func cfiNumbers(_ raw: String?) -> [Int]? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("epubcfi("), trimmed.hasSuffix(")") else { return nil }

        var withoutAssertions = ""
        var bracketDepth = 0
        for character in trimmed {
            if character == "[" {
                bracketDepth += 1
            } else if character == "]" {
                guard bracketDepth > 0 else { return nil }
                bracketDepth -= 1
            } else if bracketDepth == 0 {
                withoutAssertions.append(character)
            }
        }
        guard bracketDepth == 0 else { return nil }

        var numbers: [Int] = []
        var digits = ""
        func flush() -> Bool {
            guard digits.isEmpty == false else { return true }
            guard let value = Int(digits) else { return false }
            numbers.append(value)
            digits.removeAll(keepingCapacity: true)
            return true
        }
        for character in withoutAssertions {
            if character.isNumber {
                digits.append(character)
            } else if flush() == false {
                return nil
            }
        }
        guard flush(), numbers.isEmpty == false else { return nil }
        return numbers
    }
}

enum ExportSelection {
    static func apply(options: ExportOptions, to records: [ExportRecord]) -> [ExportRecord] {
        let filtered = records.enumerated().compactMap { index, record -> IndexedRecord? in
            guard sourceAllows(options.source, record),
                  record.isKnownCurrentPDFAnnotation == false,
                  options.bookSelectors.isEmpty || options.bookSelectors.contains(where: record.matches),
                  options.kinds.contains(record.presentationKind),
                  options.colors.map({ colors in record.presentationColor.map(colors.contains) == true }) ?? true,
                  options.underline.map({ $0 == record.isUnderline }) ?? true else {
                return nil
            }
            return IndexedRecord(index: index, record: record)
        }

        switch options.order {
        case .source:
            guard options.skipFirstPerBook > 0 else { return filtered.map(\.record) }
            var seen: [ExportDocumentKey: Int] = [:]
            return filtered.compactMap { item in
                let count = seen[item.record.documentKey, default: 0]
                seen[item.record.documentKey] = count + 1
                return count < options.skipFirstPerBook ? nil : item.record
            }
        case .reading:
            var groupOrder: [ExportDocumentKey] = []
            var groups: [ExportDocumentKey: [IndexedRecord]] = [:]
            for item in filtered {
                let key = item.record.documentKey
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(item)
            }
            return groupOrder.flatMap { key in
                let sorted = (groups[key] ?? []).sorted(by: readingOrder)
                return sorted.dropFirst(options.skipFirstPerBook).map(\.record)
            }
        }
    }

    private static func sourceAllows(_ scope: ExportSourceScope, _ record: ExportRecord) -> Bool {
        switch (scope, record.payload) {
        case (.all, _), (.epub, .epub), (.pdf, .pdf): true
        default: false
        }
    }

    private static func readingOrder(_ lhs: IndexedRecord, _ rhs: IndexedRecord) -> Bool {
        switch (lhs.record.readingKey, rhs.record.readingKey) {
        case let (.epub(left), .epub(right)):
            switch (left, right) {
            case let (left?, right?):
                let comparison = lexicographicCompare(left, right)
                return comparison == 0 ? lhs.index < rhs.index : comparison < 0
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.index < rhs.index
            }
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

    private static func lexicographicCompare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<min(lhs.count, rhs.count) {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}

private struct IndexedRecord {
    let index: Int
    let record: ExportRecord
}

enum ExportDocumentKey: Hashable, Sendable {
    case epubAsset(String)
    case epubLocalPK(Int64)
    case pdfPath(String)
}

private enum ReadingKey {
    case epub([Int]?)
    case pdf(page: Int, maxY: Double, minX: Double, traversalIndex: Int)
}

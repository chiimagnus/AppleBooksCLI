import Foundation

public struct ExportRecord: Equatable, Sendable {
    public let annotation: EnrichedAnnotation

    init(annotation: EnrichedAnnotation) {
        self.annotation = annotation
    }

    var hasHighlight: Bool {
        AnnotationContentSemantics.hasContent(annotation.annotation.selectedText)
    }

    var hasNote: Bool {
        AnnotationContentSemantics.hasContent(annotation.annotation.note)
    }

    var semanticColor: ExportPresentationColor? {
        presentationColor
    }

    var presentationColor: ExportPresentationColor? {
        switch annotation.annotation.style {
        case 1: .green
        case 2: .blue
        case 3: .yellow
        case 4: .pink
        case 5: .purple
        default: nil
        }
    }

    var isUnderline: Bool {
        annotation.annotation.isUnderline == true
    }

    var documentSourceKey: ResolvedExportSourceKey {
        annotation.annotation.rawAssetID.map(ResolvedExportSourceKey.epubAsset) ?? .epubUnknown
    }

    var isCurrentEPUBSource: Bool {
        if case let .currentLibrary(book) = annotation.source {
            return book.contentType != 3
        }
        return true
    }

    fileprivate func readingKey(chapterOrder: [String: Int]) -> EPUBAnnotationReadingKey {
        let value = annotation.annotation
        return EPUBAnnotationReadingKey.make(
            rawCFI: value.location?.rawCFI,
            chapterOrder: chapterOrder,
            createdAt: value.createdAt,
            localPK: value.localPK
        )
    }
}

enum ExportSelection {
    static func apply(
        options: ExportOptions,
        to records: [ExportRecord],
        chapterOrder: (ExportRecord) throws -> [String: Int] = { _ in [:] }
    ) throws -> [ExportRecord] {
        let filtered = records.enumerated().compactMap { index, record -> IndexedRecord? in
            guard record.isCurrentEPUBSource,
                  record.hasHighlight || record.hasNote,
                  options.hasHighlight.map({ $0 == record.hasHighlight }) ?? true,
                  options.hasNote.map({ $0 == record.hasNote }) ?? true,
                  options.colors.map({ colors in record.semanticColor.map(colors.contains) == true }) ?? true,
                  options.underline.map({ $0 == record.isUnderline }) ?? true else {
                return nil
            }
            return IndexedRecord(index: index, record: record)
        }

        var groupOrder: [ResolvedExportSourceKey] = []
        var groups: [ResolvedExportSourceKey: [IndexedRecord]] = [:]
        for item in filtered {
            let key = item.record.documentSourceKey
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(item)
        }
        return try groupOrder.flatMap { key -> [ExportRecord] in
            guard let group = groups[key], let first = group.first else { return [] }
            let chapters = try chapterOrder(first.record)
            let sorted = group.map {
                ReadingRecord(index: $0.index, record: $0.record, key: $0.record.readingKey(chapterOrder: chapters))
            }.sorted {
                EPUBAnnotationReadingKey.lessThan($0.key, $1.key)
            }
            return sorted.map(\.record)
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
    let key: EPUBAnnotationReadingKey
}

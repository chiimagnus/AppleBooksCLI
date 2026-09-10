import Foundation

package enum AnnotationQueryTextField: String, Equatable, Sendable {
    case all
    case highlight
    case note
}

package enum AnnotationQueryOrder: String, Equatable, Sendable {
    case created
    case modified
    case reading
}

package enum AnnotationQueryBookSelector: Equatable, Sendable {
    case assetID(String)
    case localPK(Int64)
}

package enum AnnotationQueryRequestError: Error, Equatable, Sendable {
    case invalidBookSelector
    case invalidText
    case textFieldRequiresText
    case invalidDateRange
    case readingOrderRequiresBook
}

final class AnnotationQueryInstrumentation {
    private(set) var readingCandidatePeak = 0
    private(set) var materializedSummaryRows = 0

    func observeReadingCandidates(_ count: Int) {
        readingCandidatePeak = max(readingCandidatePeak, count)
    }

    func observeMaterializedSummaryRow() {
        materializedSummaryRows += 1
    }
}

package struct AnnotationQueryRequest: Equatable, Sendable {
    package let book: AnnotationQueryBookSelector?
    package let text: String?
    package let textField: AnnotationQueryTextField
    package let createdAfter: Date?
    package let createdBefore: Date?
    package let modifiedAfter: Date?
    package let modifiedBefore: Date?
    package let color: AnnotationColor?
    package let underline: Bool?
    package let hasHighlight: Bool?
    package let hasNote: Bool?
    package let order: AnnotationQueryOrder
    package let limit: Int?
    package let cursor: String?

    package init(
        book: AnnotationQueryBookSelector? = nil,
        text: String? = nil,
        textField: AnnotationQueryTextField? = nil,
        createdAfter: Date? = nil,
        createdBefore: Date? = nil,
        modifiedAfter: Date? = nil,
        modifiedBefore: Date? = nil,
        color: AnnotationColor? = nil,
        underline: Bool? = nil,
        hasHighlight: Bool? = nil,
        hasNote: Bool? = nil,
        order: AnnotationQueryOrder = .modified,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws {
        if let book {
            switch book {
            case let .assetID(value):
                guard PublicStableIdentityPolicy.isEligible(value) else {
                    throw AnnotationQueryRequestError.invalidBookSelector
                }
            case let .localPK(value):
                guard value > 0 else {
                    throw AnnotationQueryRequestError.invalidBookSelector
                }
            }
        }

        if text == nil, textField != nil {
            throw AnnotationQueryRequestError.textFieldRequiresText
        }
        if let text {
            guard Self.isValidText(text) else { throw AnnotationQueryRequestError.invalidText }
        }
        let dates = [createdAfter, createdBefore, modifiedAfter, modifiedBefore].compactMap { $0 }
        guard dates.allSatisfy({ CoreDataTime.seconds(from: $0) != nil }) else {
            throw AnnotationQueryRequestError.invalidDateRange
        }
        if let createdAfter, let createdBefore, createdAfter >= createdBefore {
            throw AnnotationQueryRequestError.invalidDateRange
        }
        if let modifiedAfter, let modifiedBefore, modifiedAfter >= modifiedBefore {
            throw AnnotationQueryRequestError.invalidDateRange
        }
        if order == .reading, book == nil {
            throw AnnotationQueryRequestError.readingOrderRequiresBook
        }

        self.book = book
        self.text = text
        self.textField = textField ?? .all
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.modifiedAfter = modifiedAfter
        self.modifiedBefore = modifiedBefore
        self.color = color
        self.underline = underline
        self.hasHighlight = hasHighlight
        self.hasNote = hasNote
        self.order = order
        self.limit = limit
        self.cursor = cursor
    }

    private static func isValidText(_ value: String) -> Bool {
        var byteCount = 0
        for _ in value.utf8 {
            byteCount += 1
            if byteCount > SQLiteSemanticTextBudget.metadata { return false }
        }
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        return value.count <= 512
    }
}

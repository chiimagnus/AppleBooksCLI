import Foundation

struct EPUBAnnotationReadingKey: Equatable, Sendable {
    private enum Position: Equatable, Sendable {
        case mappedChapter(order: Int, structural: [Int])
        case structural([Int])
        case fallback(createdAt: Date?)
    }

    private let position: Position
    private let localPK: Int64

    static func make(
        rawCFI: String?,
        chapterOrder: [String: Int] = [:],
        createdAt: Date?,
        localPK: Int64
    ) -> Self {
        if let rawCFI,
           let parsed = CFIStructureParser.parse(rawCFI, collectReadingNumbers: true),
           let structural = parsed.readingNumbers {
            if let chapterID = parsed.chapterID,
               let order = chapterOrder[chapterID] {
                return Self(position: .mappedChapter(order: order, structural: structural), localPK: localPK)
            }
            return Self(position: .structural(structural), localPK: localPK)
        }
        return Self(position: .fallback(createdAt: createdAt), localPK: localPK)
    }

    static func lessThan(_ lhs: Self, _ rhs: Self) -> Bool {
        compare(lhs, rhs) < 0
    }

    private static func compare(_ lhs: Self, _ rhs: Self) -> Int {
        let positional: Int
        switch (lhs.position, rhs.position) {
        case let (.mappedChapter(leftOrder, leftStructural), .mappedChapter(rightOrder, rightStructural)):
            if leftOrder != rightOrder {
                positional = leftOrder < rightOrder ? -1 : 1
            } else {
                positional = lexicographicCompare(leftStructural, rightStructural)
            }
        case (.mappedChapter, _):
            positional = -1
        case (_, .mappedChapter):
            positional = 1
        case let (.structural(left), .structural(right)):
            positional = lexicographicCompare(left, right)
        case (.structural, .fallback):
            positional = -1
        case (.fallback, .structural):
            positional = 1
        case let (.fallback(leftDate), .fallback(rightDate)):
            switch (leftDate, rightDate) {
            case (nil, nil):
                positional = 0
            case (nil, _):
                positional = -1
            case (_, nil):
                positional = 1
            case let (left?, right?) where left != right:
                positional = left < right ? -1 : 1
            default:
                positional = 0
            }
        }
        if positional != 0 { return positional }
        if lhs.localPK == rhs.localPK { return 0 }
        return lhs.localPK < rhs.localPK ? -1 : 1
    }

    private static func lexicographicCompare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<min(lhs.count, rhs.count) {
            if lhs[index] != rhs[index] { return lhs[index] < rhs[index] ? -1 : 1 }
        }
        if lhs.count == rhs.count { return 0 }
        return lhs.count < rhs.count ? -1 : 1
    }
}

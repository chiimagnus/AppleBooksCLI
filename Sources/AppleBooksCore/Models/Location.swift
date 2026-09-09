import Foundation

public struct Location: Equatable, Sendable {
    public struct CharacterRange: Equatable, Sendable {
        public let start: Int
        public let end: Int
    }

    public let rawCFI: String
    public let chapterID: String?
    public let characterRange: CharacterRange?

    public init(rawCFI: String) {
        self.rawCFI = rawCFI
        let parsed = CFIStructureParser.parse(rawCFI)
        chapterID = parsed?.chapterID
        if let start = parsed?.rangeStart, let end = parsed?.rangeEnd {
            characterRange = CharacterRange(start: start, end: end)
        } else {
            characterRange = nil
        }
    }
}

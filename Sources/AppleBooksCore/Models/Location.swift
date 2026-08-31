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
        let parsed = Self.parse(rawCFI)
        chapterID = parsed.chapterID
        characterRange = parsed.characterRange
    }

    private static func parse(_ raw: String) -> (chapterID: String?, characterRange: CharacterRange?) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("epubcfi("), trimmed.hasSuffix(")") else {
            return (nil, nil)
        }
        let start = trimmed.index(trimmed.startIndex, offsetBy: "epubcfi(".count)
        let end = trimmed.index(before: trimmed.endIndex)
        let body = String(trimmed[start..<end])
        let spine = String(body.split(separator: "!", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")

        var chapterID: String?
        var search = spine.startIndex
        while let open = spine[search...].firstIndex(of: "[") {
            let afterOpen = spine.index(after: open)
            guard let close = spine[afterOpen...].firstIndex(of: "]") else { break }
            let hint = String(spine[afterOpen..<close])
            if hint.isEmpty == false {
                chapterID = hint
            }
            search = spine.index(after: close)
        }

        let parts = body.components(separatedBy: ",:")
        var characterRange: CharacterRange?
        if parts.count >= 3,
           let startValue = Int(parts[parts.count - 2]),
           let endValue = Int(parts[parts.count - 1].trimmingCharacters(in: .whitespacesAndNewlines)) {
            characterRange = CharacterRange(start: startValue, end: endValue)
        }
        return (chapterID, characterRange)
    }
}

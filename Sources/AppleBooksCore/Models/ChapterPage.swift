public struct ChapterPage: Equatable, Sendable {
    public let content: String
    public let offset: Int
    public let endOffset: Int
    public let totalCharacters: Int
    public let hasMore: Bool
    public let nextOffset: Int?

    init(
        content: String,
        offset: Int,
        endOffset: Int,
        totalCharacters: Int,
        hasMore: Bool,
        nextOffset: Int?
    ) {
        self.content = content
        self.offset = offset
        self.endOffset = endOffset
        self.totalCharacters = totalCharacters
        self.hasMore = hasMore
        self.nextOffset = nextOffset
    }
}

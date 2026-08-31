public enum ReadingPositionSource: Equatable, Sendable {
    case bookmarkToc
    case bookmarkHint
    case recentAnnotationInference
}

public struct ReadingPosition: Equatable, Sendable {
    public let chapterID: String
    public let title: String?
    public let order: Int?
    public let totalChapters: Int?
    public let source: ReadingPositionSource

    public init(
        chapterID: String,
        title: String?,
        order: Int?,
        totalChapters: Int?,
        source: ReadingPositionSource
    ) {
        self.chapterID = chapterID
        self.title = title
        self.order = order
        self.totalChapters = totalChapters
        self.source = source
    }
}

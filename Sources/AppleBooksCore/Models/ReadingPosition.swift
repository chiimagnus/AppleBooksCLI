public enum ReadingPositionSource: String, Codable, Equatable, Sendable {
    case bookmarkToc
    case bookmarkHint
    case recentAnnotationInference
}

package struct SemanticBookmarkedReadingPosition: Equatable, Sendable {
    package let bookLocalPK: Int64
    package let bookAssetID: String?
    package let chapterOrder: Int
    package let title: String
    package let totalChapters: Int

    package init(
        bookLocalPK: Int64,
        bookAssetID: String?,
        chapterOrder: Int,
        title: String,
        totalChapters: Int
    ) {
        self.bookLocalPK = bookLocalPK
        self.bookAssetID = bookAssetID
        self.chapterOrder = chapterOrder
        self.title = title
        self.totalChapters = totalChapters
    }
}

package enum SemanticBookmarkedReadingPositionResolution: Equatable, Sendable {
    case bookMissing
    case unavailable
    case position(SemanticBookmarkedReadingPosition)
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

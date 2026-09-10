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

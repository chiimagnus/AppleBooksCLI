public struct TopAnnotatedBookSummary: Equatable, Sendable {
    public let localPK: Int64
    public let assetID: String?
    public let annotationCount: Int

    public init(localPK: Int64, assetID: String?, annotationCount: Int) {
        self.localPK = localPK
        self.assetID = assetID
        self.annotationCount = annotationCount
    }
}

public struct LibraryStats: Equatable, Sendable {
    public let totalBooks: Int
    public let finishedBooks: Int
    public let inProgressBooks: Int
    public let unstartedBooks: Int
    public let totalUserAnnotations: Int
    public let historicalAnnotationCount: Int
    public let unmappedAnnotationCount: Int
    public let ambiguousAnnotationCount: Int
    public let identityUnavailableAnnotationCount: Int
    public let orphanUserAnnotations: Int
    public let topAnnotatedBooks: [BookOverview]
    public let topAnnotatedBookSummaries: [TopAnnotatedBookSummary]

    init(
        totalBooks: Int,
        finishedBooks: Int,
        inProgressBooks: Int,
        unstartedBooks: Int,
        totalUserAnnotations: Int,
        historicalAnnotationCount: Int,
        unmappedAnnotationCount: Int,
        ambiguousAnnotationCount: Int,
        identityUnavailableAnnotationCount: Int,
        topAnnotatedBooks: [BookOverview],
        topAnnotatedBookSummaries: [TopAnnotatedBookSummary]
    ) {
        self.totalBooks = totalBooks
        self.finishedBooks = finishedBooks
        self.inProgressBooks = inProgressBooks
        self.unstartedBooks = unstartedBooks
        self.totalUserAnnotations = totalUserAnnotations
        self.historicalAnnotationCount = historicalAnnotationCount
        self.unmappedAnnotationCount = unmappedAnnotationCount
        self.ambiguousAnnotationCount = ambiguousAnnotationCount
        self.identityUnavailableAnnotationCount = identityUnavailableAnnotationCount
        orphanUserAnnotations = historicalAnnotationCount
            + unmappedAnnotationCount
            + ambiguousAnnotationCount
            + identityUnavailableAnnotationCount
        self.topAnnotatedBooks = topAnnotatedBooks
        self.topAnnotatedBookSummaries = topAnnotatedBookSummaries
    }
}

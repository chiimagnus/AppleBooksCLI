package struct TopAnnotatedBookSummary: Equatable, Sendable {
    package let localPK: Int64
    package let assetID: String?
    package let annotationCount: Int

    package init(localPK: Int64, assetID: String?, annotationCount: Int) {
        self.localPK = localPK
        self.assetID = assetID
        self.annotationCount = annotationCount
    }
}

package struct LibraryStats: Equatable, Sendable {
    package let totalBooks: Int
    package let finishedBooks: Int
    package let inProgressBooks: Int
    package let unstartedBooks: Int
    package let totalUserAnnotations: Int
    package let historicalAnnotationCount: Int
    package let unmappedAnnotationCount: Int
    package let ambiguousAnnotationCount: Int
    package let identityUnavailableAnnotationCount: Int
    package let topAnnotatedBookSummaries: [TopAnnotatedBookSummary]

    package init(
        totalBooks: Int,
        finishedBooks: Int,
        inProgressBooks: Int,
        unstartedBooks: Int,
        totalUserAnnotations: Int,
        historicalAnnotationCount: Int,
        unmappedAnnotationCount: Int,
        ambiguousAnnotationCount: Int,
        identityUnavailableAnnotationCount: Int,
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
        self.topAnnotatedBookSummaries = topAnnotatedBookSummaries
    }
}

public struct LibraryStats: Equatable, Sendable {
    public let totalBooks: Int
    public let finishedBooks: Int
    public let inProgressBooks: Int
    public let unstartedBooks: Int
    public let totalUserAnnotations: Int
    public let orphanUserAnnotations: Int
    public let topAnnotatedBooks: [BookOverview]

    init(
        totalBooks: Int,
        finishedBooks: Int,
        inProgressBooks: Int,
        unstartedBooks: Int,
        totalUserAnnotations: Int,
        orphanUserAnnotations: Int,
        topAnnotatedBooks: [BookOverview]
    ) {
        self.totalBooks = totalBooks
        self.finishedBooks = finishedBooks
        self.inProgressBooks = inProgressBooks
        self.unstartedBooks = unstartedBooks
        self.totalUserAnnotations = totalUserAnnotations
        self.orphanUserAnnotations = orphanUserAnnotations
        self.topAnnotatedBooks = topAnnotatedBooks
    }
}

public struct BookOverview: Equatable, Sendable {
    public let book: Book
    public let userAnnotationCount: Int

    init(book: Book, userAnnotationCount: Int) {
        self.book = book
        self.userAnnotationCount = userAnnotationCount
    }
}

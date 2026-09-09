public enum BookSearchField: String, Codable, CaseIterable, Equatable, Sendable {
    case all
    case title
    case author
    case genre
}

public struct BookSummary: Equatable, Sendable {
    public let localPK: Int64
    public let assetID: String?
    public let title: String?
    public let author: String?
    public let contentType: Int64?

    public init(
        localPK: Int64,
        assetID: String?,
        title: String?,
        author: String?,
        contentType: Int64?
    ) {
        self.localPK = localPK
        self.assetID = assetID
        self.title = title
        self.author = normalizedAppleBooksAuthor(author)
        self.contentType = contentType
    }

    public var isPDF: Bool? {
        contentType.map { $0 == 3 }
    }

    package init(book: Book) {
        self.init(
            localPK: book.localPK,
            assetID: book.assetID,
            title: book.title,
            author: book.author,
            contentType: book.contentType
        )
    }
}

public struct AnnotatedBookSummary: Equatable, Sendable {
    public let book: BookSummary
    public let userAnnotationCount: Int

    public init(book: BookSummary, userAnnotationCount: Int) {
        self.book = book
        self.userAnnotationCount = userAnnotationCount
    }
}

func normalizedAppleBooksAuthor(_ author: String?) -> String? {
    guard let author else { return nil }
    let scalars = author.unicodeScalars.filter { scalar in
        scalar.value < 0xE000 || scalar.value > 0xF8FF
    }
    let normalized = String(String.UnicodeScalarView(scalars))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else { return nil }
    switch normalized.lowercased() {
    case "unknown", "unknownauthor", "unknown author":
        return nil
    default:
        return normalized
    }
}

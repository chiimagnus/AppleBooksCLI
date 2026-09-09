import AppleBooksCore
import ArgumentParser
import Foundation

struct BooksCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "books",
        abstract: "List, inspect, and search Apple Books library records.",
        subcommands: [
            BooksListCommand.self,
            BooksGetCommand.self,
            BooksSearchCommand.self,
        ]
    )
}

struct BooksListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List books with opaque cursor pagination."
    )

    @Flag(name: .long, help: "Return only books with user annotations.")
    var annotated = false

    @Option(name: .long, help: "Maximum records in this page (1...100; default 20).")
    var limit: Int?

    @Option(name: .long, help: "Opaque continuation token from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute() throws -> BookSummaryPageResult {
        try validateBookPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let dependencies: AppleBooksDependencies = annotated
                ? [.libraryRead, .annotationsRead]
                : .libraryRead
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: dependencies)
            if annotated {
                let page = try books.annotatedBookSummaryPage(limit: limit, cursor: cursor)
                return BookSummaryPageResult(
                    items: page.items.map {
                        BookSummaryResult(summary: $0.book, userAnnotationCount: $0.userAnnotationCount)
                    },
                    nextCursor: page.nextCursor,
                    hasMore: page.hasMore,
                    total: page.total
                )
            }
            let page = try books.bookSummaryPage(limit: limit, cursor: cursor)
            return BookSummaryPageResult(
                items: page.items.map { BookSummaryResult(summary: $0) },
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                total: page.total
            )
        }
    }
}

struct BooksGetCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get one book by exact asset ID or explicit local PK."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key instead of an asset ID.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> BookDetailResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            guard let book = try selector.resolve(in: books) else {
                throw CLIError.notFound("Book not found.")
            }
            return BookDetailResult(book: book)
        }
    }
}

enum BookSearchFieldOption: String, ExpressibleByArgument, CaseIterable {
    case all
    case title
    case author
    case genre

    var coreValue: BookSearchField {
        switch self {
        case .all: .all
        case .title: .title
        case .author: .author
        case .genre: .genre
        }
    }
}

struct BooksSearchCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search books using a literal title, author, or genre query."
    )

    @Argument(help: "Literal partial-match query.")
    var query: String

    @Option(name: .long, help: "Search field: all, title, author, or genre.")
    var field: BookSearchFieldOption = .all

    @Option(name: .long, help: "Maximum records in this page (1...100; default 20).")
    var limit: Int?

    @Option(name: .long, help: "Opaque continuation token from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute() throws -> BookSummaryPageResult {
        try validateBookSearchQuery(query)
        try validateBookPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            let page = try books.searchBookSummaries(
                query,
                field: field.coreValue,
                limit: limit,
                cursor: cursor
            )
            return BookSummaryPageResult(
                items: page.items.map { BookSummaryResult(summary: $0) },
                nextCursor: page.nextCursor,
                hasMore: page.hasMore,
                total: page.total
            )
        }
    }
}

private func validateBookPageInput(limit: Int?, cursor: String?) throws {
    try CLIOperation.run {
        _ = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
    }
}

private func validateBookSearchQuery(_ query: String) throws {
    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          BoundedTextPolicy.accepts(query, profile: .metadata) else {
        throw CLIError.usageInvalid("Search query is invalid or too long.")
    }
}

struct BookSummaryPageResult: Codable, Equatable, Sendable {
    let items: [BookSummaryResult]
    let nextCursor: String?
    let hasMore: Bool
    let total: Int?
}

struct BookSummaryResult: Codable, Equatable, Sendable {
    let assetID: String?
    let localPK: Int64?
    let title: String?
    let author: String?
    let isPDF: Bool?
    let userAnnotationCount: Int?
    let truncatedFields: [String]

    init(summary: BookSummary, userAnnotationCount: Int? = nil) {
        let stableAssetID = PublicStableTokenPolicy.isEligible(summary.assetID) ? summary.assetID : nil
        assetID = stableAssetID
        localPK = stableAssetID == nil && LocalPKPolicy.isEligible(summary.localPK) ? summary.localPK : nil
        var truncated: [String] = []
        title = boundedField(summary.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        author = boundedField(summary.author, field: "author", profile: .metadata, truncatedFields: &truncated)
        isPDF = summary.isPDF
        self.userAnnotationCount = userAnnotationCount
        truncatedFields = truncated
    }
}

struct BookDetailResult: Codable, Equatable, Sendable {
    let assetID: String?
    let localPK: Int64?
    let title: String?
    let author: String?
    let description: String?
    let genre: String?
    let language: String?
    let year: Int64?
    let pageCount: Int64?
    let isPDF: Bool?
    let readingProgressPercent: Double?
    let isFinished: Bool?
    let finishedDate: Date?
    let lastOpenDate: Date?
    let releaseDate: Date?
    let truncatedFields: [String]

    init(book: Book) {
        let stableAssetID = PublicStableTokenPolicy.isEligible(book.assetID) ? book.assetID : nil
        assetID = stableAssetID
        localPK = stableAssetID == nil && LocalPKPolicy.isEligible(book.localPK) ? book.localPK : nil
        var truncated: [String] = []
        title = boundedField(book.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        author = boundedField(book.normalizedAuthor, field: "author", profile: .metadata, truncatedFields: &truncated)
        description = boundedField(book.description, field: "description", profile: .detail, truncatedFields: &truncated)
        genre = boundedField(book.genre, field: "genre", profile: .metadata, truncatedFields: &truncated)
        language = boundedField(book.language, field: "language", profile: .shortMetadata, truncatedFields: &truncated)
        year = book.year
        pageCount = book.pageCount
        isPDF = book.contentType.map { $0 == 3 }
        if let raw = book.readingProgressRaw, raw.isFinite {
            readingProgressPercent = min(max(raw, 0), 1) * 100
        } else {
            readingProgressPercent = nil
        }
        isFinished = book.isFinished
        finishedDate = book.finishedDate
        lastOpenDate = book.lastOpenDate
        releaseDate = book.releaseDate
        truncatedFields = truncated
    }
}

struct BookResult: Codable, Equatable, Sendable {
    let localPK: Int64
    let assetID: String?
    let title: String?
    let author: String?
    let normalizedAuthor: String?
    let description: String?
    let epubID: String?
    let genre: String?
    let genresRaw: Data?
    let comments: String?
    let language: String?
    let year: Int64?
    let contentType: Int64?
    let pageCount: Int64?
    let path: String?
    let fileSize: Int64?
    let coverURL: String?
    let isFinished: Bool?
    let readingProgressRaw: Double?
    let readingProgressPercent: Double?
    let durationRawMilliseconds: Double?
    let durationSeconds: Double?
    let creationDate: Date?
    let modificationDate: Date?
    let finishedDate: Date?
    let lastOpenDate: Date?
    let purchaseDate: Date?
    let releaseDate: Date?
    let isExplicit: Bool?
    let isLocked: Bool?
    let isEphemeral: Bool?
    let isHidden: Bool?
    let isSample: Bool?
    let isStoreAudiobook: Bool?
    let rating: Double?
    let userAnnotationCount: Int?

    init(book: Book, userAnnotationCount: Int? = nil) {
        localPK = book.localPK
        assetID = book.assetID
        title = book.title
        author = book.author
        normalizedAuthor = book.normalizedAuthor
        description = book.description
        epubID = book.epubID
        genre = book.genre
        genresRaw = book.genresRaw
        comments = book.comments
        language = book.language
        year = book.year
        contentType = book.contentType
        pageCount = book.pageCount
        path = book.path
        fileSize = book.fileSize
        coverURL = book.coverURL
        isFinished = book.isFinished
        readingProgressRaw = book.readingProgressRaw
        readingProgressPercent = book.readingProgressPercent
        durationRawMilliseconds = book.durationRawMilliseconds
        durationSeconds = book.durationSeconds
        creationDate = book.creationDate
        modificationDate = book.modificationDate
        finishedDate = book.finishedDate
        lastOpenDate = book.lastOpenDate
        purchaseDate = book.purchaseDate
        releaseDate = book.releaseDate
        isExplicit = book.isExplicit
        isLocked = book.isLocked
        isEphemeral = book.isEphemeral
        isHidden = book.isHidden
        isSample = book.isSample
        isStoreAudiobook = book.isStoreAudiobook
        rating = book.rating
        self.userAnnotationCount = userAnnotationCount
    }

    init(overview: BookOverview) {
        self.init(book: overview.book, userAnnotationCount: overview.userAnnotationCount)
    }

}


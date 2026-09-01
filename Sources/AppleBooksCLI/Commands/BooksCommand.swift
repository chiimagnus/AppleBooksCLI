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
            BooksGenreCommand.self,
        ]
    )
}

struct BooksListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List books with deterministic pagination."
    )

    @Flag(name: .long, help: "Return only books with user annotations.")
    var annotated = false

    @Flag(name: .long, help: "Use the unlimited P2 list surface instead of the default content page.")
    var all = false

    @Option(name: .long, help: "Limit the result page.")
    var limit: Int?

    @Option(name: .long, help: "Offset into the stable result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> BookPageResult {
        if all, limit != nil {
            throw ValidationError("--all cannot be combined with --limit.")
        }
        guard offset >= 0 else {
            throw ValidationError("--offset must be non-negative.")
        }

        if annotated {
            return try annotatedResult()
        }
        if all {
            return try CLIOperation.run {
                let appleBooks = try CLIContext(global: global).makeAppleBooks()
                let allBooks = try appleBooks.listBooks()
                let visibleBooks = offset == 0 ? allBooks : try appleBooks.listBooks(offset: offset)
                return BookPageResult(
                    items: visibleBooks.map { BookResult(book: $0) },
                    total: allBooks.count,
                    limit: nil,
                    offset: offset
                )
            }
        }

        if let limit, (1...100).contains(limit) == false {
            throw ValidationError("--limit must be between 1 and 100 for paged book lists.")
        }
        return try CLIOperation.run {
            let page = try CLIContext(global: global).makeAppleBooks().bookPage(limit: limit, offset: offset)
            return BookPageResult(
                items: page.items.map { BookResult(book: $0) },
                total: page.total,
                limit: page.limit,
                offset: page.offset
            )
        }
    }

    private func annotatedResult() throws -> BookPageResult {
        try CLIOperation.run {
            let overviews = try CLIContext(global: global).makeAppleBooks().annotatedBooks()
            if all {
                return BookPageResult(
                    items: overviews.dropFirst(offset).map { BookResult(overview: $0) },
                    total: overviews.count,
                    limit: nil,
                    offset: offset
                )
            }

            let effectiveLimit = limit ?? 20
            guard (1...100).contains(effectiveLimit) else {
                throw CLIError.usageInvalid("--limit must be between 1 and 100 for paged book lists.")
            }
            // ponytail: annotatedBooks 目前只有完整数组 surface；这里只做稳定结果数组分页，core 若增加 page owner 就删除这段切片。
            let items = overviews.dropFirst(offset).prefix(effectiveLimit).map { BookResult(overview: $0) }
            return BookPageResult(
                items: items,
                total: overviews.count,
                limit: effectiveLimit,
                offset: offset
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> BookResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let overview = try selector.resolveOverview(in: books) else {
                throw CLIError.notFound("Book not found.")
            }
            return BookResult(overview: overview)
        }
    }
}

struct BooksSearchCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search title, author, and genre using the core literal search owner."
    )

    @Argument(help: "Literal partial-match query.")
    var query: String

    @Option(name: .long, help: "Limit the stable search result page.")
    var limit: Int?

    @Option(name: .long, help: "Offset into the stable search result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> BookPageResult {
        try validateSearchInput(query: query, limit: limit, offset: offset)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let allMatches = try books.books(matching: query)
            let pageItems: [Book]
            if limit == nil, offset == 0 {
                pageItems = allMatches
            } else {
                pageItems = try books.books(matching: query, limit: limit, offset: offset)
            }
            return BookPageResult(
                items: pageItems.map { BookResult(book: $0) },
                total: allMatches.count,
                limit: limit,
                offset: offset
            )
        }
    }
}

struct BooksGenreCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "genre",
        abstract: "Search the canonical genre field using literal partial matching."
    )

    @Argument(help: "Literal genre query.")
    var query: String

    @Option(name: .long, help: "Limit the stable genre result page.")
    var limit: Int?

    @Option(name: .long, help: "Offset into the stable genre result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> BookPageResult {
        try validateSearchInput(query: query, limit: limit, offset: offset)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let allMatches = try books.books(matchingGenre: query)
            let pageItems: [Book]
            if limit == nil, offset == 0 {
                pageItems = allMatches
            } else {
                pageItems = try books.books(matchingGenre: query, limit: limit, offset: offset)
            }
            return BookPageResult(
                items: pageItems.map { BookResult(book: $0) },
                total: allMatches.count,
                limit: limit,
                offset: offset
            )
        }
    }
}

private func validateSearchInput(query: String, limit: Int?, offset: Int) throws {
    guard query.isEmpty == false else {
        throw ValidationError("Search query must not be empty.")
    }
    if let limit, limit <= 0 {
        throw ValidationError("--limit must be positive.")
    }
    guard offset >= 0 else {
        throw ValidationError("--offset must be non-negative.")
    }
}

struct BookPageResult: Codable, Equatable, Sendable {
    let items: [BookResult]
    let total: Int
    let limit: Int?
    let offset: Int

    var humanDescription: String {
        var lines = ["total: \(total)"]
        lines.append(contentsOf: items.map(\.humanSummary))
        return lines.joined(separator: "\n")
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

    var humanDescription: String {
        [
            "local PK: \(localPK)",
            "asset ID: \(assetID ?? "-")",
            "title: \(title ?? "-")",
            "author: \(author ?? "-")",
            "user annotations: \(userAnnotationCount.map(String.init) ?? "-")",
        ].joined(separator: "\n")
    }

    var humanSummary: String {
        "\(localPK)\t\(assetID ?? "-")\t\(title ?? "-")\t\(author ?? "-")"
    }
}


import AppleBooksCore
import ArgumentParser

struct ReadingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reading",
        abstract: "Inspect canonical Apple Books reading state and position.",
        subcommands: [
            ReadingInProgressCommand.self,
            ReadingFinishedCommand.self,
            ReadingUnstartedCommand.self,
            ReadingRecentCommand.self,
            ReadingPositionCommand.self,
        ]
    )
}

enum ReadingStatusKind {
    case inProgress
    case finished
    case unstarted
    case recent

    func fetch(from books: AppleBooks, limit: Int?, offset: Int) throws -> ReadingBooksResult {
        let items: [Book]
        let effectiveLimit: Int?
        switch self {
        case .inProgress:
            items = try books.booksInProgress(limit: limit, offset: offset)
            effectiveLimit = limit
        case .finished:
            items = try books.finishedBooks(limit: limit, offset: offset)
            effectiveLimit = limit
        case .unstarted:
            items = try books.unstartedBooks(limit: limit, offset: offset)
            effectiveLimit = limit
        case .recent:
            let recentLimit = limit ?? 10
            items = try books.recentlyReadBooks(limit: recentLimit, offset: offset)
            effectiveLimit = recentLimit
        }
        return ReadingBooksResult(
            items: items.map { BookResult(book: $0) },
            limit: effectiveLimit,
            offset: offset
        )
    }
}

protocol ReadingStatusLeaf: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    var limit: Int? { get }
    var offset: Int { get }
    var global: GlobalOptions { get }
    var statusKind: ReadingStatusKind { get }
}

extension ReadingStatusLeaf {
    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        if let limit, limit <= 0 {
            throw ValidationError("--limit must be positive.")
        }
        guard offset >= 0 else {
            throw ValidationError("--offset must be non-negative.")
        }
        let result = try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            return try statusKind.fetch(from: books, limit: limit, offset: offset)
        }
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct ReadingInProgressCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "in-progress")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var offset = 0
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .inProgress }
}

struct ReadingFinishedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "finished")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var offset = 0
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .finished }
}

struct ReadingUnstartedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "unstarted")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var offset = 0
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .unstarted }
}

struct ReadingRecentCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "recent")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var offset = 0
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .recent }
}

struct ReadingPositionCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "position",
        abstract: "Resolve the canonical current reading position for one book."
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
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        let result = try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let book = try selector.resolve(in: books) else {
                throw CLIError.notFound("Book not found.")
            }
            guard let position = try books.currentReadingPosition(forBookLocalPK: book.localPK) else {
                throw CLIError.unavailable("Reading position is unavailable for this book.")
            }
            return ReadingPositionResult(book: book, position: position)
        }

        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct ReadingBooksResult: Codable, Equatable, Sendable {
    let items: [BookResult]
    let limit: Int?
    let offset: Int

    var humanDescription: String {
        items.isEmpty ? "No books." : items.map(\.humanSummary).joined(separator: "\n")
    }
}

struct ReadingPositionResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let chapterID: String
    let title: String?
    let order: Int?
    let totalChapters: Int?
    let source: ReadingPositionSource

    init(book: Book, position: ReadingPosition) {
        bookLocalPK = book.localPK
        bookAssetID = book.assetID
        chapterID = position.chapterID
        title = position.title
        order = position.order
        totalChapters = position.totalChapters
        source = position.source
    }

    var humanDescription: String {
        [
            "book: \(bookAssetID ?? String(bookLocalPK))",
            "chapter: \(chapterID)",
            "title: \(title ?? "-")",
            "order: \(order.map(String.init) ?? "-")",
            "total chapters: \(totalChapters.map(String.init) ?? "-")",
            "source: \(source.rawValue)",
        ].joined(separator: "\n")
    }
}

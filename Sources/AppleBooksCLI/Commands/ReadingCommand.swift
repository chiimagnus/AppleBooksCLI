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

    func fetch(from books: AppleBooks, limit: Int?, cursor: String?) throws -> ReadingBooksResult {
        let page: CursorPage<BookSummary>
        switch self {
        case .inProgress:
            page = try books.semanticBooksInProgressPage(limit: limit, cursor: cursor)
        case .finished:
            page = try books.semanticFinishedBooksPage(limit: limit, cursor: cursor)
        case .unstarted:
            page = try books.semanticUnstartedBooksPage(limit: limit, cursor: cursor)
        case .recent:
            page = try books.semanticRecentlyReadBooksPage(limit: limit, cursor: cursor)
        }
        return ReadingBooksResult(
            items: page.items.map { BookSummaryResult(summary: $0) },
            nextCursor: page.nextCursor,
            hasMore: page.hasMore
        )
    }
}

protocol ReadingStatusLeaf: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    var limit: Int? { get }
    var cursor: String? { get }
    var global: GlobalOptions { get }
    var statusKind: ReadingStatusKind { get }
}

extension ReadingStatusLeaf {
    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try validateReadingPageInput(limit: limit, cursor: cursor)
        let result = try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            return try statusKind.fetch(from: books, limit: limit, cursor: cursor)
        }
        try output.writeJSON(result)
    }
}

struct ReadingInProgressCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "in-progress")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .inProgress }
}

struct ReadingFinishedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "finished")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .finished }
}

struct ReadingUnstartedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "unstarted")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .unstarted }
}

struct ReadingRecentCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(commandName: "recent")
    @Option(name: .long) var limit: Int?
    @Option(name: .long) var cursor: String?
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
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            guard let book = try selector.resolveSemanticDetail(in: books) else {
                throw CLIError.notFound("Book not found.")
            }
            guard let position = try books.semanticCurrentReadingPosition(forBookLocalPK: book.localPK) else {
                throw CLIError.unavailable("Reading position is unavailable for this book.")
            }
            let includeLocalPK: Bool
            if case .localPK = selector {
                includeLocalPK = true
            } else {
                includeLocalPK = false
            }
            return ReadingPositionResult(book: book, position: position, includeLocalPK: includeLocalPK)
        }

        try output.writeJSON(result)
    }
}

private func validateReadingPageInput(limit: Int?, cursor: String?) throws {
    try CLIOperation.run {
        _ = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
    }
}

struct ReadingBooksResult: Codable, Equatable, Sendable {
    let items: [BookSummaryResult]
    let nextCursor: String?
    let hasMore: Bool
}

struct ReadingPositionResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64?
    let bookAssetID: String?
    let chapterID: String
    let title: String?
    let order: Int?
    let totalChapters: Int?
    let source: ReadingPositionSource

    init(book: SemanticBookDetail, position: ReadingPosition, includeLocalPK: Bool = false) {
        let stableAssetID = PublicStableTokenPolicy.isEligible(book.assetID) ? book.assetID : nil
        bookAssetID = stableAssetID
        bookLocalPK = (stableAssetID == nil || includeLocalPK) && LocalPKPolicy.isEligible(book.localPK) ? book.localPK : nil
        chapterID = position.chapterID
        title = position.title
        order = position.order
        totalChapters = position.totalChapters
        source = position.source
    }

}

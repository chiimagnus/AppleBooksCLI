import AppleBooksCore
import ArgumentParser

struct ReadingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reading",
        abstract: "Inspect Apple Books reading state and bookmarked position.",
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

protocol ReadingStatusLeaf: ParsableCommand, CLIOutputRunnable {
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
    static let configuration = CommandConfiguration(
        commandName: "in-progress",
        abstract: "List books currently being read."
    )
    @Option(name: .long, help: "Maximum books in this page (default 20, max 100).") var limit: Int?
    @Option(name: .long, help: "Opaque continuation cursor from the previous page.") var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .inProgress }
}

struct ReadingFinishedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(
        commandName: "finished",
        abstract: "List finished books."
    )
    @Option(name: .long, help: "Maximum books in this page (default 20, max 100).") var limit: Int?
    @Option(name: .long, help: "Opaque continuation cursor from the previous page.") var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .finished }
}

struct ReadingUnstartedCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(
        commandName: "unstarted",
        abstract: "List books not yet started."
    )
    @Option(name: .long, help: "Maximum books in this page (default 20, max 100).") var limit: Int?
    @Option(name: .long, help: "Opaque continuation cursor from the previous page.") var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .unstarted }
}

struct ReadingRecentCommand: ReadingStatusLeaf {
    static let configuration = CommandConfiguration(
        commandName: "recent",
        abstract: "List recently read books."
    )
    @Option(name: .long, help: "Maximum books in this page (default 20, max 100).") var limit: Int?
    @Option(name: .long, help: "Opaque continuation cursor from the previous page.") var cursor: String?
    @OptionGroup var global: GlobalOptions
    var statusKind: ReadingStatusKind { .recent }
}

struct ReadingPositionCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "position",
        abstract: "Resolve the current bookmarked reading position when it maps to an actionable chapter."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local book primary key instead of an asset ID.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        let result = try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            let resolution: SemanticBookmarkedReadingPositionResolution
            switch selector {
            case let .assetID(assetID):
                resolution = try books.semanticBookmarkedReadingPosition(bookAssetID: assetID)
            case let .localPK(localPK):
                resolution = try books.semanticBookmarkedReadingPosition(bookLocalPK: localPK)
            }
            switch resolution {
            case .bookMissing:
                throw CLIError.notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
            case .unavailable:
                throw CLIError.unavailableWithReason(
                    message: "Reading position is unavailable for this book.",
                    reason: .readingPositionUnavailable
                )
            case let .position(position):
                return ReadingPositionResult(position)
            }
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
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool
}

struct ReadingPositionResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64?
    let bookAssetID: String?
    let chapterOrder: Int
    let title: String
    let totalChapters: Int
    let truncatedFields: [String]

    init(_ position: SemanticBookmarkedReadingPosition) {
        bookAssetID = position.bookAssetID
        bookLocalPK = position.bookAssetID == nil && LocalPKPolicy.isEligible(position.bookLocalPK)
            ? position.bookLocalPK
            : nil
        chapterOrder = position.chapterOrder
        let boundedTitle = BoundedTextPolicy.truncate(position.title, profile: .metadata)
        title = boundedTitle.value ?? ""
        totalChapters = position.totalChapters
        truncatedFields = boundedTitle.truncated ? ["title"] : []
    }
}

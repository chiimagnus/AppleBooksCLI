import AppleBooksCore
import ArgumentParser

struct CollectionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "List, inspect, search, and read Apple Books collections.",
        subcommands: [
            CollectionsListCommand.self,
            CollectionsGetCommand.self,
            CollectionsSearchCommand.self,
            CollectionsBooksCommand.self,
        ]
    )
}

struct CollectionsListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List non-deleted collections in the canonical stable order."
    )

    @Option(name: .long, parsing: .unconditional, help: "Limit the stable collection order.")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Offset into the stable collection order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute() throws -> CollectionPageResult {
        try validateCollectionPagination(limit: limit, offset: offset)
        return try CLIOperation.run {
            let rows = try CLIContext(global: global).makeAppleBooks().listCollections(limit: limit, offset: offset)
            return CollectionPageResult(items: rows.map(CollectionResult.init), limit: limit, offset: offset)
        }
    }
}

struct CollectionsGetCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get one collection by exact collection ID or explicit local primary key."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute() throws -> CollectionResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let collection = try selector.resolve(in: books) else {
                throw CLIError.notFound("Collection not found.")
            }
            return CollectionResult(collection)
        }
    }
}

struct CollectionsSearchCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search collection titles using the core literal substring owner."
    )

    @Argument(help: "Literal title substring.")
    var query: String

    @Option(name: .long, parsing: .unconditional, help: "Limit the stable search order.")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Offset into the stable search order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute() throws -> CollectionPageResult {
        guard query.isEmpty == false else { throw ValidationError("Search query must not be empty.") }
        try validateCollectionPagination(limit: limit, offset: offset)
        return try CLIOperation.run {
            let rows = try CLIContext(global: global).makeAppleBooks()
                .collections(matchingTitle: query, limit: limit, offset: offset)
            return CollectionPageResult(items: rows.map(CollectionResult.init), limit: limit, offset: offset)
        }
    }
}

struct CollectionsBooksCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "books",
        abstract: "List books in one collection using the canonical membership order."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute() throws -> CollectionBooksResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let members = try selector.resolveBooks(in: books) else {
                throw CLIError.notFound("Collection not found.")
            }
            return CollectionBooksResult(items: members.map { BookResult(book: $0) })
        }
    }
}

struct CollectionPageResult: Codable, Equatable, Sendable {
    let items: [CollectionResult]
    let limit: Int?
    let offset: Int

    var humanDescription: String {
        guard items.isEmpty == false else { return "No collections." }
        return items.map(\.humanSummary).joined(separator: "\n")
    }
}

struct CollectionBooksResult: Codable, Equatable, Sendable {
    let items: [BookResult]

    var humanDescription: String {
        guard items.isEmpty == false else { return "No books." }
        return items.map(\.humanSummary).joined(separator: "\n")
    }
}

struct CollectionResult: Codable, Equatable, Sendable {
    let localPK: Int64
    let collectionID: String?
    let title: String?
    let details: String?
    let isDeleted: Bool?
    let isHidden: Bool?

    init(_ collection: Collection) {
        localPK = collection.localPK
        collectionID = collection.collectionID
        title = collection.title
        details = collection.details
        isDeleted = collection.isDeleted
        isHidden = collection.isHidden
    }

    var humanDescription: String {
        [
            "local PK: \(localPK)",
            "collection ID: \(collectionID ?? "-")",
            "title: \(title ?? "-")",
            "details: \(details ?? "-")",
            "hidden: \(isHidden.map(String.init) ?? "-")",
        ].joined(separator: "\n")
    }

    var humanSummary: String {
        "\(localPK)\t\(collectionID ?? "-")\t\(title ?? "-")\t\(isHidden.map(String.init) ?? "-")"
    }
}

private func validateCollectionPagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 { throw ValidationError("--limit must be positive.") }
    guard offset >= 0 else { throw ValidationError("--offset must be non-negative.") }
}

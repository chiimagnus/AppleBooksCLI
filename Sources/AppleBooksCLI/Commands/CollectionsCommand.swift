import AppleBooksCore
import ArgumentParser
import Foundation

struct CollectionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collections",
        abstract: "List, inspect, search, and read Apple Books collections.",
        subcommands: [
            CollectionsListCommand.self,
            CollectionsGetCommand.self,
            CollectionsSearchCommand.self,
            CollectionsBooksCommand.self,
            CollectionsCreateCommand.self,
            CollectionsRenameCommand.self,
            CollectionsDeleteCommand.self,
            CollectionsAddBookCommand.self,
            CollectionsRemoveBookCommand.self,
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

struct CollectionsCreateCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a collection through the guarded mutation rail."
    )

    @Argument(help: "New collection title.")
    var title: String

    @Option(name: .long, help: "Optional collection details.")
    var details: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try books.createCollection(title: title, details: details))
        }
    }
}

struct CollectionsRenameCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename one collection by exact ID or explicit local primary key."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @Option(name: .customLong("title"), help: "Replacement collection title.")
    var title: String

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selector.rename(to: title, in: books))
        }
    }
}

struct CollectionsDeleteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one editable collection by exact ID or explicit local primary key."
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

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selector.delete(in: books))
        }
    }
}

struct CollectionsAddBookCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "add-book",
        abstract: "Add one exact book to one exact collection through the guarded mutation rail."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .customLong("collection-pk"), parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var collectionPK: Int64?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selectors.collection.add(selectors.book, in: books))
        }
    }
}

struct CollectionsRemoveBookCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "remove-book",
        abstract: "Remove one exact book from one exact collection through the guarded mutation rail."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .customLong("collection-pk"), parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var collectionPK: Int64?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selectors.collection.remove(selectors.book, in: books))
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
    let isPlaceholder: Bool?
    let sortKey: Int64?
    let sortMode: Int64?
    let viewMode: Int64?
    let lastModificationDate: Date?
    let localModificationDate: Date?

    init(_ collection: Collection) {
        localPK = collection.localPK
        collectionID = collection.collectionID
        title = collection.title
        details = collection.details
        isDeleted = collection.isDeleted
        isHidden = collection.isHidden
        isPlaceholder = collection.isPlaceholder
        sortKey = collection.sortKey
        sortMode = collection.sortMode
        viewMode = collection.viewMode
        lastModificationDate = collection.lastModificationDate
        localModificationDate = collection.localModificationDate
    }

    var humanDescription: String {
        [
            "local PK: \(localPK)",
            "collection ID: \(collectionID ?? "-")",
            "title: \(title ?? "-")",
            "details: \(details ?? "-")",
            "hidden: \(isHidden.map(String.init) ?? "-")",
            "sort key: \(sortKey.map(String.init) ?? "-")",
            "last modification: \(lastModificationDate.map { $0.formatted(.iso8601) } ?? "-")",
        ].joined(separator: "\n")
    }

    var humanSummary: String {
        "\(localPK)\t\(collectionID ?? "-")\t\(title ?? "-")\t\(isHidden.map(String.init) ?? "-")"
    }
}

private func parseCollectionMembershipSelectors(
    collectionID: String?,
    assetID: String?,
    collectionPK: Int64?,
    bookPK: Int64?
) throws -> (collection: CollectionSelector, book: BookSelector) {
    var effectiveCollectionID = collectionID
    var effectiveAssetID = assetID

    // ArgumentParser assigns a single positional to the first optional argument.
    // With an explicit collection PK, that positional semantically belongs to the book selector.
    if collectionPK != nil, effectiveAssetID == nil, let positional = effectiveCollectionID {
        effectiveCollectionID = nil
        effectiveAssetID = positional
    }

    let collection = try parseCollectionSelector(
        collectionID: effectiveCollectionID,
        localPK: collectionPK,
        localPKOptionName: "--collection-pk"
    )
    let book = try parseBookSelector(assetID: effectiveAssetID, localPK: bookPK)
    return (collection, book)
}

private func validateCollectionPagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 { throw ValidationError("--limit must be positive.") }
    guard offset >= 0 else { throw ValidationError("--offset must be non-negative.") }
}

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
        abstract: "List non-deleted collections with opaque cursor pagination."
    )

    @Option(name: .long, parsing: .unconditional, help: "Maximum collections in this page (default 20, max 100).")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> CollectionPageResult {
        try validateCollectionPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let page = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
                .semanticCollectionSummaryPage(limit: limit, cursor: cursor)
            return CollectionPageResult(
                items: page.items.map(CollectionSummaryResult.init),
                nextCursor: page.nextCursor,
                hasMore: page.hasMore
            )
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
        try output.writeJSON(result)
    }

    func execute() throws -> CollectionDetailResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            guard let collection = try selector.resolveSemantic(in: books) else {
                throw CLIError.notFoundWithReason(message: "Collection not found.", reason: .collectionNotFound)
            }
            return CollectionDetailResult(collection)
        }
    }
}

struct CollectionsSearchCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search collection titles by literal substring."
    )

    @Argument(help: "Literal title substring.")
    var query: String

    @Option(name: .long, parsing: .unconditional, help: "Maximum collections in this page (default 20, max 100).")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> CollectionPageResult {
        try validateCollectionSearchInput(query)
        try validateCollectionPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let page = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
                .semanticCollectionSummaryPage(matchingTitle: query, limit: limit, cursor: cursor)
            return CollectionPageResult(
                items: page.items.map(CollectionSummaryResult.init),
                nextCursor: page.nextCursor,
                hasMore: page.hasMore
            )
        }
    }
}

struct CollectionsBooksCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "books",
        abstract: "List books in one collection with opaque cursor pagination."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @Option(name: .long, parsing: .unconditional, help: "Maximum books in this page (default 20, max 100).")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> CollectionBooksResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        try validateCollectionPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            guard let page = try selector.resolveBookSummaryPage(in: books, limit: limit, cursor: cursor) else {
                throw CLIError.notFoundWithReason(message: "Collection not found.", reason: .collectionNotFound)
            }
            return CollectionBooksResult(
                items: page.items.map { BookSummaryResult(summary: $0) },
                nextCursor: page.nextCursor,
                hasMore: page.hasMore
            )
        }
    }
}

struct CollectionsCreateCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a new Apple Books collection."
    )

    @Argument(help: "New collection title. Leading and trailing whitespace is removed; max 512 characters / 8 KiB UTF-8.")
    var title: String

    @Flag(name: .long, help: "Wait for Apple Books to acknowledge this committed change on this Mac.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "collections.create" }

    func historyRequest() throws -> OperationHistoryRequest {
        OperationHistoryRequest(title: try canonicalCollectionTitle(title), syncRequested: sync)
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> CollectionMutationCommandResult {
        let canonicalTitle = try canonicalCollectionTitle(title)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .collectionWrite)
            let mutation = try books.createCollection(title: canonicalTitle, syncCloud: sync)
            historySink?.record(.mutation(mutation))
            return CollectionMutationCommandResult(mutation)
        }
    }
}

struct CollectionsRenameCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "rename",
        abstract: "Rename one collection by exact ID or explicit local primary key."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @Option(name: .customLong("title"), help: "Replacement title. Leading and trailing whitespace is removed; max 512 characters / 8 KiB UTF-8.")
    var title: String

    @Flag(name: .long, help: "Wait for Apple Books to acknowledge this committed change on this Mac.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "collections.rename" }

    func historyRequest() throws -> OperationHistoryRequest {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return OperationHistoryRequest(
            selector: selector.historySelector,
            title: try canonicalCollectionTitle(title),
            syncRequested: sync
        )
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> CollectionMutationCommandResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        let canonicalTitle = try canonicalCollectionTitle(title)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .collectionWrite)
            let mutation = try selector.rename(to: canonicalTitle, in: books, syncCloud: sync)
            historySink?.record(.mutation(mutation, inverse: .collectionRename(mutation)))
            return CollectionMutationCommandResult(mutation, selector: selector)
        }
    }
}

struct CollectionsDeleteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one editable collection by exact ID or explicit local primary key."
    )

    @Argument(help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var pk: Int64?

    @Flag(name: .long, help: "Wait for Apple Books to acknowledge this committed change on this Mac.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "collections.delete" }

    func historyRequest() throws -> OperationHistoryRequest {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return OperationHistoryRequest(selector: selector.historySelector, syncRequested: sync)
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> CollectionMutationCommandResult {
        let selector = try parseCollectionSelector(collectionID: collectionID, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .collectionWrite)
            let mutation = try selector.delete(in: books, syncCloud: sync)
            historySink?.record(.mutation(mutation))
            return CollectionMutationCommandResult(mutation, selector: selector)
        }
    }
}

struct CollectionsAddBookCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "add-book",
        abstract: "Add one exact book to one exact collection."
    )

    @Option(name: .customLong("collection"), help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .customLong("book"), help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .customLong("collection-pk"), parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var collectionPK: Int64?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @Flag(name: .long, help: "Wait for Apple Books to acknowledge this committed change on this Mac.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "collections.add-book" }

    func historyRequest() throws -> OperationHistoryRequest {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return OperationHistoryRequest(
            selector: selectors.book.addingHistoryIdentity(to: selectors.collection.historySelector),
            syncRequested: sync
        )
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> MembershipMutationCommandResult {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .collectionWrite)
            let mutation = try selectors.collection.add(selectors.book, in: books, syncCloud: sync)
            historySink?.record(.mutation(
                mutation,
                inverse: .membership(mutation, operation: "collections.remove-book")
            ))
            return MembershipMutationCommandResult(
                mutation,
                collection: selectors.collection,
                book: selectors.book
            )
        }
    }
}

struct CollectionsRemoveBookCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "remove-book",
        abstract: "Remove one exact book from one exact collection."
    )

    @Option(name: .customLong("collection"), help: "Exact Apple Books collection ID.")
    var collectionID: String?

    @Option(name: .customLong("book"), help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .customLong("collection-pk"), parsing: .unconditional, help: "Use an explicit local collection primary key.")
    var collectionPK: Int64?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @Flag(name: .long, help: "Wait for Apple Books to acknowledge this committed change on this Mac.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "collections.remove-book" }

    func historyRequest() throws -> OperationHistoryRequest {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return OperationHistoryRequest(
            selector: selectors.book.addingHistoryIdentity(to: selectors.collection.historySelector),
            syncRequested: sync
        )
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> MembershipMutationCommandResult {
        let selectors = try parseCollectionMembershipSelectors(
            collectionID: collectionID,
            assetID: assetID,
            collectionPK: collectionPK,
            bookPK: bookPK
        )
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .collectionWrite)
            let mutation = try selectors.collection.remove(selectors.book, in: books, syncCloud: sync)
            historySink?.record(.mutation(
                mutation,
                inverse: .membership(mutation, operation: "collections.add-book")
            ))
            return MembershipMutationCommandResult(
                mutation,
                collection: selectors.collection,
                book: selectors.book
            )
        }
    }
}

struct CollectionPageResult: Codable, Equatable, Sendable {
    let items: [CollectionSummaryResult]
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool
}

struct CollectionBooksResult: Codable, Equatable, Sendable {
    let items: [BookSummaryResult]
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool
}

struct CollectionSummaryResult: Codable, Equatable, Sendable {
    let collectionID: String?
    let localPK: Int64?
    let title: String?
    let canEditCollection: Bool
    let canEditMembership: Bool
    let truncatedFields: [String]

    init(_ collection: SemanticCollectionSummary) {
        let stableID = PublicStableTokenPolicy.isEligible(collection.collectionID) ? collection.collectionID : nil
        collectionID = stableID
        localPK = stableID == nil && LocalPKPolicy.isEligible(collection.localPK) ? collection.localPK : nil
        var truncated = collection.byteTruncatedFields
        title = boundedField(collection.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        canEditCollection = collection.canEditCollection
        canEditMembership = collection.canEditMembership
        truncatedFields = Array(Set(truncated)).sorted()
    }
}

struct CollectionDetailResult: Codable, Equatable, Sendable {
    let collectionID: String?
    let localPK: Int64?
    let title: String?
    let details: String?
    let isHidden: Bool?
    let canEditCollection: Bool
    let canEditMembership: Bool
    let truncatedFields: [String]

    init(_ collection: SemanticCollection) {
        let stableID = PublicStableTokenPolicy.isEligible(collection.collectionID) ? collection.collectionID : nil
        collectionID = stableID
        localPK = stableID == nil && LocalPKPolicy.isEligible(collection.localPK) ? collection.localPK : nil
        var truncated = collection.byteTruncatedFields
        title = boundedField(collection.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        details = boundedField(collection.details, field: "details", profile: .detail, truncatedFields: &truncated)
        isHidden = collection.isHidden
        canEditCollection = collection.canEditCollection
        canEditMembership = collection.canEditMembership
        truncatedFields = Array(Set(truncated)).sorted()
    }
}

private func parseCollectionMembershipSelectors(
    collectionID: String?,
    assetID: String?,
    collectionPK: Int64?,
    bookPK: Int64?
) throws -> (collection: CollectionSelector, book: BookSelector) {
    let collection = try parseCollectionSelector(
        collectionID: collectionID,
        localPK: collectionPK,
        localPKOptionName: "--collection-pk"
    )
    guard let book = try parseOptionalBookSelector(
        assetID: assetID,
        localPK: bookPK,
        localPKOptionName: "--book-pk"
    ) else {
        throw ValidationError("Provide --book or --book-pk.")
    }
    return (collection, book)
}

private func validateCollectionPageInput(limit: Int?, cursor: String?) throws {
    try CLIOperation.run {
        _ = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
    }
}

private func canonicalCollectionTitle(_ raw: String) throws -> String {
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title.isEmpty == false,
          BoundedTextPolicy.accepts(title, profile: .metadata) else {
        throw CLIError.usageInvalid("Collection title must be non-empty and at most 512 characters / 8 KiB UTF-8 after trimming.")
    }
    return title
}

private func validateCollectionSearchInput(_ query: String) throws {
    guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
          BoundedTextPolicy.accepts(query, profile: .metadata) else {
        throw CLIError.usageInvalid("Search query must be non-empty and within the metadata input limit.")
    }
}

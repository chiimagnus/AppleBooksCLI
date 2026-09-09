import AppleBooksCore
import ArgumentParser
import Foundation

struct ContentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content",
        abstract: "Inspect EPUB content.",
        subcommands: [
            ContentStatusCommand.self,
            ContentMetadataCommand.self,
            ContentCoverCommand.self,
            ContentLocateCommand.self,
            ContentChaptersCommand.self,
            ContentChapterCommand.self,
            ContentCurrentChapterCommand.self,
        ]
    )
}

struct ContentStatusCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(commandName: "status")

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentStatusResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let book = try requireSemanticBook(selector, in: books)
            guard let status = try books.semanticContentStatus(forBookLocalPK: book.localPK) else {
                throw CLIError.notFound("Book not found.")
            }
            return ContentStatusResult(status)
        }
    }
}

struct ContentMetadataCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(commandName: "metadata")

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentMetadataResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let book = try requireSemanticBook(selector, in: books)
            guard let inspection = try books.semanticContentMetadata(forBookLocalPK: book.localPK) else {
                throw CLIError.notFound("Book not found.")
            }
            return ContentMetadataResult(inspection)
        }
    }
}

struct ContentCoverCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(commandName: "cover")

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @Option(name: .customLong("output"), help: "Absolute destination file path. Existing files are never replaced.")
    var outputPath: String

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentCoverResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        guard outputPath.hasPrefix("/") else {
            throw ValidationError("--output must be an absolute file path.")
        }
        let destination = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard destination.lastPathComponent.isEmpty == false else {
            throw ValidationError("--output must name a file.")
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let book = try requireSemanticBook(selector, in: books)
            guard let inspection = try books.semanticContentCover(forBookLocalPK: book.localPK) else {
                throw CLIError.unavailable("Book cover is unavailable.")
            }
            let writer = try ExportFileWriter(outputRoot: destination.deletingLastPathComponent())
            let writeResult = try writer.write(
                inspection.cover.data,
                fileName: destination.lastPathComponent,
                overwrite: .never
            )
            return ContentCoverResult(inspection: inspection, disposition: writeResult.disposition)
        }
    }
}

struct ContentLocateCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(commandName: "locate")

    @Argument(help: "With asset ID: <asset-id> <cfi>. With --pk: <cfi>.")
    var values: [String] = []

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentLocationResult {
        let parsed = try parseBookSelectorAndValue(values: values, localPK: pk, valueName: "CFI")
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let book = try requireSemanticBook(parsed.selector, in: books)
            guard let inspection = try books.semanticLocate(rawCFI: parsed.value, forBookLocalPK: book.localPK) else {
                throw CLIError.notFound("Book not found.")
            }
            return ContentLocationResult(inspection)
        }
    }
}

struct ContentChaptersCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "chapters",
        abstract: "List the canonical EPUB table of contents with opaque cursor pagination."
    )

    @Option(name: .customLong("book"), help: "Use an exact Apple Books asset ID.")
    var book: String?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @Option(name: .long, parsing: .unconditional, help: "Page size (default 20, maximum 100).")
    var limit: Int?

    @Option(name: .long, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute() throws -> ContentChaptersPageResult {
        let selector = try parseOptionalBookSelector(
            assetID: book,
            localPK: bookPK,
            localPKOptionName: "--book-pk"
        )
        guard let selector else {
            throw ValidationError("Provide exactly one of --book or --book-pk.")
        }
        try CLIOperation.run {
            _ = try resolvedCursorPageLimit(limit)
            try validateCursorInputSyntax(cursor)
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let page: SemanticChapterListPage?
            switch selector {
            case let .assetID(assetID):
                page = try books.semanticChapterListPage(bookAssetID: assetID, limit: limit, cursor: cursor)
            case let .localPK(localPK):
                page = try books.semanticChapterListPage(bookLocalPK: localPK, limit: limit, cursor: cursor)
            }
            guard let page else { throw CLIError.notFound("Book not found.") }
            return ContentChaptersPageResult(page)
        }
    }
}

struct ContentChapterCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "chapter",
        abstract: "Read one EPUB chapter by table-of-contents order with opaque continuation."
    )

    @Option(name: .customLong("book"), help: "Use an exact Apple Books asset ID.")
    var book: String?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @Option(name: .customLong("chapter"), parsing: .unconditional, help: "Positive chapter order returned by `content chapters`.")
    var chapterOrder: Int

    @Option(name: .customLong("max-chars"), parsing: .unconditional, help: "Maximum grapheme count in this page (default 4000, max 16000).")
    var maxCharacters: Int?

    @Option(name: .long, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentChapterPageResult {
        guard chapterOrder > 0 else {
            throw ValidationError("--chapter must be a positive chapter order.")
        }
        if let maxCharacters, (1...ChapterContinuationPolicy.maximumCharacters).contains(maxCharacters) == false {
            throw ValidationError("--max-chars must be between 1 and 16000.")
        }
        let selector = try parseOptionalBookSelector(
            assetID: book,
            localPK: bookPK,
            localPKOptionName: "--book-pk"
        )
        guard let selector else {
            throw ValidationError("Provide exactly one of --book or --book-pk.")
        }
        try CLIOperation.run { try validateCursorInputSyntax(cursor) }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let page: SemanticChapterContinuationPage?
            switch selector {
            case let .assetID(assetID):
                page = try books.semanticChapterPage(
                    bookAssetID: assetID,
                    chapterOrder: chapterOrder,
                    maximumCharacters: maxCharacters,
                    cursor: cursor
                )
            case let .localPK(localPK):
                page = try books.semanticChapterPage(
                    bookLocalPK: localPK,
                    chapterOrder: chapterOrder,
                    maximumCharacters: maxCharacters,
                    cursor: cursor
                )
            }
            guard let page else { throw CLIError.notFound("Book not found.") }
            return ContentChapterPageResult(page)
        }
    }
}

struct ContentCurrentChapterCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "current-chapter",
        abstract: "Resolve the current type-3 bookmark chapter without annotation fallback."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> ContentCurrentChapterResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            let book = try requireSemanticBook(selector, in: books)
            guard let chapter = try books.semanticCurrentReadingChapter(forBookLocalPK: book.localPK) else {
                throw CLIError.unavailable("Current reading chapter is unavailable.")
            }
            return ContentCurrentChapterResult(book: book, chapter: chapter)
        }
    }
}

private func parseBookSelectorAndValue(
    values: [String],
    localPK: Int64?,
    valueName: String
) throws -> (selector: BookSelector, value: String) {
    if let localPK {
        guard values.count == 1 else {
            throw ValidationError("With --pk, provide exactly one \(valueName).")
        }
        return (try parseBookSelector(assetID: nil, localPK: localPK), values[0])
    }
    guard values.count == 2 else {
        throw ValidationError("Provide an asset ID followed by a \(valueName), or use --pk with one \(valueName).")
    }
    return (try parseBookSelector(assetID: values[0], localPK: nil), values[1])
}

private func requireSemanticBook(_ selector: BookSelector, in books: AppleBooks) throws -> SemanticBookDetail {
    guard let book = try selector.resolveSemanticDetail(in: books) else {
        throw CLIError.notFound("Book not found.")
    }
    return book
}

struct ContentStatusResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let currentAvailability: BookContentAvailability?
    let supplementalAvailability: BookContentAvailability?
    let selectedSource: EPUBContentSource?
    let materialization: BookContentAvailability
    let encryption: EPUBEncryption?
    let unavailableReason: EPUBContentUnavailableReason?
    let ready: Bool

    init(_ status: EPUBContentStatus) {
        bookLocalPK = status.bookLocalPK
        bookAssetID = status.bookAssetID
        currentAvailability = status.currentAvailability
        supplementalAvailability = status.supplementalAvailability
        selectedSource = status.selectedSource
        materialization = status.materialization
        encryption = status.encryption
        unavailableReason = status.unavailableReason
        ready = status.isReady
    }

}

struct ContentMetadataResult: Codable, Equatable, Sendable {
    struct Database: Codable, Equatable, Sendable {
        let localPK: Int64
        let assetID: String?
        let title: String?
        let author: String?
        let language: String?
        let releaseDate: Date?
    }

    struct RawEPUB: Codable, Equatable, Sendable {
        let title: String?
        let creator: String?
        let identifiers: [String]
        let isbn: String?
        let language: String?
        let publisher: String?
        let publicationDate: String?
        let rights: String?
        let subjects: [String]
    }

    struct Enrichment: Codable, Equatable, Sendable {
        let isbn: String?
        let language: String?
        let publisher: String?
        let publicationDate: String?
        let rights: String?
        let subjects: [String]
    }

    let source: EPUBContentSource
    let database: Database
    let epub: RawEPUB
    let enrichment: Enrichment

    init(_ inspection: SemanticEPUBMetadataInspection) {
        let book = inspection.book
        source = inspection.source
        database = Database(
            localPK: book.localPK,
            assetID: book.assetID,
            title: book.title,
            author: book.author,
            language: book.language,
            releaseDate: book.releaseDate
        )
        let metadata = inspection.metadata
        epub = RawEPUB(
            title: metadata.title,
            creator: metadata.creator,
            identifiers: metadata.identifiers,
            isbn: metadata.isbn,
            language: metadata.language,
            publisher: metadata.publisher,
            publicationDate: metadata.publicationDate,
            rights: metadata.rights,
            subjects: metadata.subjects
        )
        let enrichment = inspection.enrichment
        self.enrichment = Enrichment(
            isbn: enrichment.isbn,
            language: enrichment.language,
            publisher: enrichment.publisher,
            publicationDate: enrichment.publicationDate,
            rights: enrichment.rights,
            subjects: enrichment.subjects
        )
    }

}

struct ContentCoverResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let contentSource: EPUBContentSource
    let coverSource: EPUBCoverSource
    let mediaType: String?
    let byteCount: Int
    let outputStatus: ExportFileWriteDisposition

    init(inspection: EPUBCoverInspection, disposition: ExportFileWriteDisposition) {
        bookLocalPK = inspection.bookLocalPK
        bookAssetID = inspection.bookAssetID
        contentSource = inspection.source
        coverSource = inspection.cover.source
        mediaType = inspection.cover.mediaType
        byteCount = inspection.cover.data.count
        outputStatus = disposition
    }

}

struct ContentChapterResult: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let href: String
    let fragment: String
    let order: Int
    let depth: Int

    init(_ chapter: Chapter) {
        id = chapter.id
        title = chapter.title
        href = chapter.href
        fragment = chapter.fragment
        order = chapter.order
        depth = chapter.depth
    }

}

struct ContentChapterSummaryResult: Codable, Equatable, Sendable {
    let chapterOrder: Int
    let title: String
    let depth: Int
    let truncatedFields: [String]

    init(_ chapter: SemanticChapterSummary) {
        chapterOrder = chapter.chapterOrder
        let boundedTitle = BoundedTextPolicy.truncate(chapter.title, profile: .metadata)
        title = boundedTitle.value ?? ""
        depth = chapter.depth
        truncatedFields = boundedTitle.truncated ? ["title"] : []
    }
}

struct ContentChaptersPageResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let items: [ContentChapterSummaryResult]
    let nextCursor: String?
    let hasMore: Bool

    init(_ page: SemanticChapterListPage) {
        let stableAssetID = PublicStableTokenPolicy.isEligible(page.bookAssetID) ? page.bookAssetID : nil
        bookAssetID = stableAssetID
        bookLocalPK = stableAssetID == nil && LocalPKPolicy.isEligible(page.bookLocalPK)
            ? page.bookLocalPK
            : nil
        items = page.items.map(ContentChapterSummaryResult.init)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
    }
}

struct ContentChapterPageResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let chapterOrder: Int
    let content: String
    let hasMore: Bool
    let nextCursor: String?

    init(_ page: SemanticChapterContinuationPage) {
        bookAssetID = page.bookAssetID
        bookLocalPK = page.bookAssetID == nil ? page.bookLocalPK : nil
        chapterOrder = page.chapterOrder
        content = page.content
        hasMore = page.hasMore
        nextCursor = page.nextCursor
    }
}

struct ContentCurrentChapterResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let chapter: ContentChapterResult

    init(book: SemanticBookDetail, chapter: Chapter) {
        bookLocalPK = book.localPK
        bookAssetID = book.assetID
        self.chapter = ContentChapterResult(chapter)
    }

}

struct ContentLocationResult: Codable, Equatable, Sendable {
    struct CharacterRangeResult: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
    }

    let bookLocalPK: Int64
    let bookAssetID: String?
    let rawCFI: String
    let chapterID: String?
    let characterRange: CharacterRangeResult?
    let source: EPUBContentSource?
    let resolvedChapter: ContentChapterResult?

    init(_ inspection: EPUBLocationInspection) {
        bookLocalPK = inspection.bookLocalPK
        bookAssetID = inspection.bookAssetID
        rawCFI = inspection.location.rawCFI
        chapterID = inspection.location.chapterID
        characterRange = inspection.location.characterRange.map {
            CharacterRangeResult(start: $0.start, end: $0.end)
        }
        source = inspection.source
        resolvedChapter = inspection.chapter.map(ContentChapterResult.init)
    }

}

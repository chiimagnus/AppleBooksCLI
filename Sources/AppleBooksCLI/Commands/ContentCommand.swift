import AppleBooksCore
import ArgumentParser
import Foundation

struct ContentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content",
        abstract: "Inspect EPUB content.",
        subcommands: [
            ContentMetadataCommand.self,
            ContentCoverCommand.self,
            ContentChaptersCommand.self,
            ContentChapterCommand.self,
        ]
    )
}

struct ContentMetadataCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "metadata",
        abstract: "Read metadata for one EPUB book."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local book primary key.")
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
            let inspection: SemanticEPUBMetadataInspection?
            switch selector {
            case let .assetID(assetID):
                inspection = try books.semanticContentMetadata(bookAssetID: assetID)
            case let .localPK(localPK):
                inspection = try books.semanticContentMetadata(bookLocalPK: localPK)
            }
            guard let inspection else {
                throw CLIError.notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
            }
            return ContentMetadataResult(inspection)
        }
    }
}

struct ContentCoverCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "cover",
        abstract: "Write the cover image for one EPUB book."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local book primary key.")
    var pk: Int64?

    @Option(name: .customLong("output"), help: "Destination file path, relative to the current directory or absolute. Existing files are never replaced.")
    var outputPath: String

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(currentDirectory: URL? = nil) throws -> ContentCoverResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        let destination = try resolveContentCoverDestination(
            outputPath,
            currentDirectory: currentDirectory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        )

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .configuration])
            let inspection: EPUBCoverInspection?
            switch selector {
            case let .assetID(assetID):
                inspection = try books.semanticContentCover(bookAssetID: assetID)
            case let .localPK(localPK):
                inspection = try books.semanticContentCover(bookLocalPK: localPK)
            }
            guard let inspection else {
                throw CLIError.unavailable("Book cover is unavailable.")
            }
            let writer = try ExportFileWriter(outputRoot: destination.deletingLastPathComponent())
            let writeResult = try writer.writeIncrementally(
                fileName: destination.lastPathComponent,
                overwrite: .never
            ) { sink in
                try sink(inspection.cover.data)
            }
            return ContentCoverResult(inspection: inspection, writeResult: writeResult)
        }
    }
}

struct ContentChaptersCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "chapters",
        abstract: "List an EPUB table of contents with opaque cursor pagination."
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
            guard let page else {
                throw CLIError.notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
            }
            return ContentChaptersPageResult(page)
        }
    }
}

struct ContentChapterCommand: ParsableCommand, CLIOutputRunnable {
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
            guard let page else {
                throw CLIError.notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
            }
            return ContentChapterPageResult(page)
        }
    }
}

struct ContentMetadataResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let contentSource: EPUBContentSource
    let title: String?
    let author: String?
    let isbn: String?
    let language: String?
    let publisher: String?
    let publicationDate: String?
    let rights: String?
    let subjects: [String]
    let truncatedFields: [String]

    init(_ inspection: SemanticEPUBMetadataInspection) {
        let metadata = inspection.metadata
        let fallback = inspection.databaseFallback
        bookAssetID = inspection.bookAssetID
        bookLocalPK = inspection.bookAssetID == nil && LocalPKPolicy.isEligible(inspection.bookLocalPK)
            ? inspection.bookLocalPK
            : nil
        contentSource = inspection.source

        var truncated = fallback.byteTruncatedFields
        title = boundedField(fallback.title ?? metadata.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        author = boundedField(fallback.author ?? metadata.creator, field: "author", profile: .metadata, truncatedFields: &truncated)
        isbn = boundedField(metadata.isbn, field: "isbn", profile: .shortMetadata, truncatedFields: &truncated)
        language = boundedField(fallback.language ?? metadata.language, field: "language", profile: .shortMetadata, truncatedFields: &truncated)
        publisher = boundedField(metadata.publisher, field: "publisher", profile: .metadata, truncatedFields: &truncated)
        let resolvedPublicationDate = fallback.releaseDate.map(Self.iso8601) ?? metadata.publicationDate
        publicationDate = boundedField(resolvedPublicationDate, field: "publicationDate", profile: .shortMetadata, truncatedFields: &truncated)
        rights = boundedField(metadata.rights, field: "rights", profile: .detail, truncatedFields: &truncated)

        let subjectProfile = BoundedTextProfile(maximumGraphemes: 256, maximumUTF8Bytes: 4 * 1_024)
        var boundedSubjects: [String] = []
        boundedSubjects.reserveCapacity(min(metadata.subjects.count, 32))
        var subjectsTruncated = metadata.subjects.count > 32
        for subject in metadata.subjects.prefix(32) {
            let bounded = BoundedTextPolicy.truncate(subject, profile: subjectProfile)
            if bounded.truncated { subjectsTruncated = true }
            if let value = bounded.value { boundedSubjects.append(value) }
        }
        subjects = boundedSubjects
        if subjectsTruncated { truncated.append("subjects") }
        truncatedFields = Array(Set(truncated)).sorted()
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

struct ContentCoverResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let contentSource: EPUBContentSource
    let coverSource: EPUBCoverSource
    let mediaType: String?
    let byteCount: Int
    let destination: String
    let disposition: ExportFileWriteDisposition

    init(inspection: EPUBCoverInspection, writeResult: ExportFileWriteResult) {
        bookAssetID = inspection.bookAssetID
        bookLocalPK = inspection.bookAssetID == nil && LocalPKPolicy.isEligible(inspection.bookLocalPK)
            ? inspection.bookLocalPK
            : nil
        contentSource = inspection.source
        coverSource = inspection.cover.source
        mediaType = inspection.cover.mediaType
        byteCount = inspection.cover.data.count
        destination = writeResult.destination.path
        disposition = writeResult.disposition
    }
}

private func resolveContentCoverDestination(_ path: String, currentDirectory: URL) throws -> URL {
    guard path.isEmpty == false,
          path.unicodeScalars.contains(where: { $0.value == 0 }) == false,
          currentDirectory.isFileURL,
          currentDirectory.path.hasPrefix("/") else {
        throw ValidationError("--output must name a valid file path.")
    }
    let destination = path.hasPrefix("/")
        ? URL(fileURLWithPath: path).standardizedFileURL
        : currentDirectory.appendingPathComponent(path, isDirectory: false).standardizedFileURL
    guard destination.path.hasPrefix("/"),
          destination.lastPathComponent.isEmpty == false,
          destination.path != "/" else {
        throw ValidationError("--output must name a file.")
    }
    return destination
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
    @ExplicitNullString var nextCursor: String?
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
    @ExplicitNullString var nextCursor: String?

    init(_ page: SemanticChapterContinuationPage) {
        bookAssetID = page.bookAssetID
        bookLocalPK = page.bookAssetID == nil ? page.bookLocalPK : nil
        chapterOrder = page.chapterOrder
        content = page.content
        hasMore = page.hasMore
        nextCursor = page.nextCursor
    }
}

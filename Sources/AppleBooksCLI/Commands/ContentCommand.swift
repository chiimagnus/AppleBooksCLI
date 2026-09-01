import AppleBooksCore
import ArgumentParser
import Foundation

struct ContentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content",
        abstract: "Inspect EPUB content and annotation context.",
        subcommands: [
            ContentStatusCommand.self,
            ContentMetadataCommand.self,
            ContentCoverCommand.self,
            ContentLocateCommand.self,
            ContentChaptersCommand.self,
            ContentChapterCommand.self,
            ContentCurrentChapterCommand.self,
            ContentContextCommand.self,
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentStatusResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(selector, in: books)
            guard let status = try books.contentStatus(forBookLocalPK: book.localPK) else {
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentMetadataResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(selector, in: books)
            guard let inspection = try books.contentMetadata(forBookLocalPK: book.localPK) else {
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
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
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(selector, in: books)
            guard let inspection = try books.contentCover(forBookLocalPK: book.localPK) else {
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentLocationResult {
        let parsed = try parseBookSelectorAndValue(values: values, localPK: pk, valueName: "CFI")
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(parsed.selector, in: books)
            guard let inspection = try books.locate(rawCFI: parsed.value, forBookLocalPK: book.localPK) else {
                throw CLIError.notFound("Book not found.")
            }
            return ContentLocationResult(inspection)
        }
    }
}

struct ContentChaptersCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "chapters",
        abstract: "List the canonical EPUB table of contents."
    )

    @Argument(help: "Exact Apple Books asset ID.")
    var assetID: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentChaptersResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(selector, in: books)
            let chapters = try books.bookContent(forBookLocalPK: book.localPK).listChapters()
            return ContentChaptersResult(book: book, chapters: chapters)
        }
    }
}

struct ContentChapterCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "chapter",
        abstract: "Read one EPUB chapter with grapheme-safe pagination."
    )

    @Argument(help: "With asset ID: <asset-id> <chapter-selector>. With --pk: <chapter-selector>.")
    var values: [String] = []

    @Option(name: .long, help: "Use an explicit local Core Data primary key.")
    var pk: Int64?

    @Option(name: .long, parsing: .unconditional, help: "Requested grapheme offset. Negative values clamp to zero.")
    var offset: Int = 0

    @Option(name: .customLong("max-chars"), parsing: .unconditional, help: "Maximum grapheme count to return. Omit to read to the end.")
    var maxCharacters: Int?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentChapterPageResult {
        let parsed = try parseBookSelectorAndValue(
            values: values,
            localPK: pk,
            valueName: "chapter selector"
        )
        if let maxCharacters, maxCharacters <= 0 {
            throw ValidationError("--max-chars must be greater than zero.")
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(parsed.selector, in: books)
            let page = try books.bookContent(forBookLocalPK: book.localPK).chapterPage(
                id: parsed.value,
                offset: offset,
                maxCharacters: maxCharacters
            )
            return ContentChapterPageResult(
                book: book,
                chapterSelector: parsed.value,
                requestedOffset: offset,
                page: page
            )
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentCurrentChapterResult {
        let selector = try parseBookSelector(assetID: assetID, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(selector, in: books)
            guard let chapter = try books.currentReadingChapter(forBookLocalPK: book.localPK) else {
                throw CLIError.unavailable("Current reading chapter is unavailable.")
            }
            return ContentCurrentChapterResult(book: book, chapter: chapter)
        }
    }
}

struct ContentContextCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Resolve canonical context around one user annotation."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, help: "Use an explicit local Core Data primary key instead of a UUID.")
    var pk: Int64?

    @Option(name: .long, parsing: .unconditional, help: "Maximum graphemes before the matched annotation anchor.")
    var before = 300

    @Option(name: .long, parsing: .unconditional, help: "Maximum graphemes after the matched annotation anchor.")
    var after = 300

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> ContentContextResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        guard before >= 0, after >= 0 else {
            throw ValidationError("--before and --after must be non-negative.")
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let enriched = try selector.resolve(in: books) else {
                throw CLIError.notFound("Annotation not found.")
            }
            let context = try books.annotationContext(
                localPK: enriched.annotation.localPK,
                charsBefore: before,
                charsAfter: after
            )
            return ContentContextResult(annotation: enriched.annotation, context: context)
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

private func requireBook(_ selector: BookSelector, in books: AppleBooks) throws -> Book {
    guard let book = try selector.resolve(in: books) else {
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

    var humanDescription: String {
        [
            "book: \(bookAssetID ?? String(bookLocalPK))",
            "ready: \(ready)",
            "current availability: \(currentAvailability?.rawValue ?? "unconfigured")",
            "supplemental availability: \(supplementalAvailability?.rawValue ?? "unconfigured")",
            "selected source: \(selectedSource?.rawValue ?? "-")",
            "materialization: \(materialization.rawValue)",
            "encryption: \(encryption?.rawValue ?? "-")",
            "unavailable reason: \(unavailableReason?.rawValue ?? "-")",
        ].joined(separator: "\n")
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

    init(_ inspection: EPUBMetadataInspection) {
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

    var humanDescription: String {
        [
            "book: \(database.assetID ?? String(database.localPK))",
            "title: \(database.title ?? "-")",
            "author: \(database.author ?? "-")",
            "source: \(source.rawValue)",
            "EPUB title: \(epub.title ?? "-")",
            "EPUB creator: \(epub.creator ?? "-")",
            "ISBN: \(enrichment.isbn ?? "-")",
            "publisher: \(enrichment.publisher ?? "-")",
        ].joined(separator: "\n")
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

    var humanDescription: String {
        [
            "book: \(bookAssetID ?? String(bookLocalPK))",
            "source: \(contentSource.rawValue)",
            "cover source: \(coverSource.rawValue)",
            "media type: \(mediaType ?? "unknown")",
            "bytes: \(byteCount)",
            "output: \(outputStatus.rawValue)",
        ].joined(separator: "\n")
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

    var humanDescription: String {
        "order=\(order) depth=\(depth) id=\(id) title=\(title) href=\(href) fragment=\(fragment)"
    }
}

struct ContentChaptersResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let chapters: [ContentChapterResult]

    init(book: Book, chapters: [Chapter]) {
        bookLocalPK = book.localPK
        bookAssetID = book.assetID
        self.chapters = chapters.map(ContentChapterResult.init)
    }

    var humanDescription: String {
        guard chapters.isEmpty == false else { return "No chapters." }
        return chapters.map(\.humanDescription).joined(separator: "\n")
    }
}

struct ContentChapterPageResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let chapterSelector: String
    let requestedOffset: Int
    let effectiveOffset: Int
    let endOffset: Int
    let totalCharacters: Int
    let hasMore: Bool
    let nextOffset: Int?
    let content: String

    init(book: Book, chapterSelector: String, requestedOffset: Int, page: ChapterPage) {
        bookLocalPK = book.localPK
        bookAssetID = book.assetID
        self.chapterSelector = chapterSelector
        self.requestedOffset = requestedOffset
        effectiveOffset = page.offset
        endOffset = page.endOffset
        totalCharacters = page.totalCharacters
        hasMore = page.hasMore
        nextOffset = page.nextOffset
        content = page.content
    }

    var humanDescription: String {
        [
            "chapter: \(chapterSelector)",
            "requested offset: \(requestedOffset)",
            "effective offset: \(effectiveOffset)",
            "end offset: \(endOffset)",
            "total characters: \(totalCharacters)",
            "has more: \(hasMore)",
            "next offset: \(nextOffset.map(String.init) ?? "-")",
            "",
            content,
        ].joined(separator: "\n")
    }
}

struct ContentCurrentChapterResult: Codable, Equatable, Sendable {
    let bookLocalPK: Int64
    let bookAssetID: String?
    let chapter: ContentChapterResult

    init(book: Book, chapter: Chapter) {
        bookLocalPK = book.localPK
        bookAssetID = book.assetID
        self.chapter = ContentChapterResult(chapter)
    }

    var humanDescription: String { chapter.humanDescription }
}

struct ContentContextResult: Codable, Equatable, Sendable {
    let annotationLocalPK: Int64
    let annotationUUID: String?
    let before: String
    let matched: String
    let after: String
    let leadingTruncated: Bool
    let trailingTruncated: Bool
    let canonicalText: String
    let matchFound: Bool
    let presentationText: String

    init(annotation: Annotation, context: AnnotationContext) {
        let presentation = context.markedPresentation
        annotationLocalPK = annotation.localPK
        annotationUUID = annotation.uuid
        before = context.before
        matched = context.matched
        after = context.after
        leadingTruncated = context.leadingTruncated
        trailingTruncated = context.trailingTruncated
        canonicalText = context.text
        matchFound = presentation.matched
        presentationText = presentation.text
    }

    var humanDescription: String { presentationText }
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

    var humanDescription: String {
        [
            "book: \(bookAssetID ?? String(bookLocalPK))",
            "chapter hint: \(chapterID ?? "-")",
            "range: \(characterRange.map { "\($0.start)..<\($0.end)" } ?? "-")",
            "source: \(source?.rawValue ?? "-")",
            "resolved chapter: \(resolvedChapter?.id ?? "-")",
        ].joined(separator: "\n")
    }
}

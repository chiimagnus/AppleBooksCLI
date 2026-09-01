import AppleBooksCore
import ArgumentParser
import Foundation

struct ContentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "content",
        abstract: "Inspect EPUB availability, metadata, covers, and CFI locations.",
        subcommands: [
            ContentStatusCommand.self,
            ContentMetadataCommand.self,
            ContentCoverCommand.self,
            ContentLocateCommand.self,
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
        let parsed = try parsedArguments()
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let book = try requireBook(parsed.selector, in: books)
            guard let inspection = try books.locate(rawCFI: parsed.rawCFI, forBookLocalPK: book.localPK) else {
                throw CLIError.notFound("Book not found.")
            }
            return ContentLocationResult(inspection)
        }
    }

    private func parsedArguments() throws -> (selector: BookSelector, rawCFI: String) {
        if let pk {
            guard values.count == 1 else {
                throw ValidationError("With --pk, provide exactly one CFI argument.")
            }
            return (try parseBookSelector(assetID: nil, localPK: pk), values[0])
        }
        guard values.count == 2 else {
            throw ValidationError("Provide an asset ID followed by a CFI, or use --pk with one CFI.")
        }
        return (try parseBookSelector(assetID: values[0], localPK: nil), values[1])
    }
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

struct ContentLocationResult: Codable, Equatable, Sendable {
    struct CharacterRangeResult: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
    }

    struct ChapterResult: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let href: String
        let fragment: String
        let order: Int
        let depth: Int
    }

    let bookLocalPK: Int64
    let bookAssetID: String?
    let rawCFI: String
    let chapterID: String?
    let characterRange: CharacterRangeResult?
    let source: EPUBContentSource?
    let resolvedChapter: ChapterResult?

    init(_ inspection: EPUBLocationInspection) {
        bookLocalPK = inspection.bookLocalPK
        bookAssetID = inspection.bookAssetID
        rawCFI = inspection.location.rawCFI
        chapterID = inspection.location.chapterID
        characterRange = inspection.location.characterRange.map {
            CharacterRangeResult(start: $0.start, end: $0.end)
        }
        source = inspection.source
        resolvedChapter = inspection.chapter.map {
            ChapterResult(
                id: $0.id,
                title: $0.title,
                href: $0.href,
                fragment: $0.fragment,
                order: $0.order,
                depth: $0.depth
            )
        }
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

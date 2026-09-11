import AppleBooksCore
import ArgumentParser
import Foundation

struct PDFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Inspect PDF inventory and extract highlights.",
        subcommands: [PDFListCommand.self, PDFHighlightsCommand.self]
    )
}

struct PDFListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List available PDF sources and stable selectors."
    )

    @Option(name: .long, parsing: .unconditional, help: "Maximum PDF sources in this page (default 20, max 100).")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> PDFSourceListResult {
        try validatePDFPageInput(limit: limit, cursor: cursor)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)
            let page = try books.semanticPDFSourcePage(limit: limit, cursor: cursor)
            return PDFSourceListResult(
                items: page.items.map(PDFInventoryResult.init),
                nextCursor: page.nextCursor,
                hasMore: page.hasMore
            )
        }
    }
}

struct PDFHighlightsCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "highlights",
        abstract: "Read one bounded page of highlights from exactly one PDF source."
    )

    @Option(name: .customLong("book"), help: "Use an exact Apple Books asset ID returned by `pdf list`.")
    var book: String?

    @Option(name: .customLong("pdf"), help: "Use an opaque PDF source ID returned by `pdf list`.")
    var pdfSourceID: String?

    @Option(name: .long, parsing: .unconditional, help: "Maximum highlights in this page (default 20, max 100).")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute(
        workerURL injectedWorkerURL: URL? = nil,
        using injectedBooks: AppleBooks? = nil
    ) throws -> PDFHighlightPageResult {
        let selection = try parseSelection()
        try validatePDFPageInput(limit: limit, cursor: cursor)

        let books: AppleBooks
        if let injectedBooks {
            books = injectedBooks
        } else {
            let workerURL = try injectedWorkerURL ?? installedPDFWorkerURL()
            books = try CLIContext(global: global).makeAppleBooks(
                dependencies: [.libraryRead, .pdfWorker],
                pdfWorkerURL: workerURL,
                pdfWorkerTimeout: AppleBooks.defaultPDFWorkerTimeout
            )
        }

        return try CLIOperation.run {
            let source: PDFSource
            switch selection {
            case let .bookAssetID(assetID):
                guard let resolved = try books.semanticPDFSource(bookAssetID: assetID) else {
                    throw CLIError.notFoundWithReason(
                        message: "PDF source not found.",
                        reason: .pdfSourceNotFound
                    )
                }
                source = resolved
            case let .sourceID(sourceID):
                guard let resolved = try books.semanticPDFSource(sourceID: sourceID) else {
                    throw CLIError.notFoundWithReason(
                        message: "PDF source not found.",
                        reason: .pdfSourceNotFound
                    )
                }
                source = resolved
            }
            return PDFHighlightPageResult(
                try books.semanticPDFHighlightPage(source: source, limit: limit, cursor: cursor)
            )
        }
    }

    private func parseSelection() throws -> PDFCLISelection {
        if let book { try PublicStableTokenPolicy.validateInput(book) }
        let sourceID: PDFSourceID?
        if let pdfSourceID {
            do {
                sourceID = try PDFSourceID.parse(pdfSourceID)
            } catch {
                throw CLIError.usageInvalid("--pdf must be an opaque PDF source ID returned by `pdf list`.")
            }
        } else {
            sourceID = nil
        }
        guard (book == nil) != (sourceID == nil) else {
            throw ValidationError("Provide exactly one of --book or --pdf.")
        }
        if let book { return .bookAssetID(book) }
        return .sourceID(sourceID!)
    }
}

private enum PDFCLISelection {
    case bookAssetID(String)
    case sourceID(PDFSourceID)
}

struct PDFSourceListResult: Codable, Equatable, Sendable {
    let items: [PDFInventoryResult]
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool
}

struct PDFInventoryResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let pdfSourceID: String?
    let title: String?
    let provenance: String
    let truncatedFields: [String]

    init(_ source: PDFInventorySummary) {
        bookAssetID = source.bookAssetID
        pdfSourceID = source.pdfSourceID
        var truncated = source.byteTruncatedFields
        title = boundedField(source.title, field: "title", profile: .metadata, truncatedFields: &truncated)
        provenance = source.provenance.rawValue
        truncatedFields = Array(Set(truncated)).sorted()
    }
}

private func validatePDFPageInput(limit: Int?, cursor: String?) throws {
    try CLIOperation.run {
        _ = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
    }
}

struct PDFHighlightPageResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let pdfSourceID: String?
    let items: [PDFHighlightSummaryResult]
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool

    init(_ page: SemanticPDFHighlightPage) {
        bookAssetID = page.bookAssetID
        pdfSourceID = page.pdfSourceID
        items = page.items.map(PDFHighlightSummaryResult.init)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
    }
}

struct PDFHighlightSummaryResult: Codable, Equatable, Sendable {
    let page: Int
    let note: String?
    let text: String?
    let modifiedAt: Date?
    let textApproximate: Bool
    let presentationColor: PDFHighlightPresentationColorResult?
    let truncatedFields: [String]

    init(_ item: PDFAgentHighlightSummary) {
        page = item.page
        var truncated = item.truncatedFields
        note = boundedField(item.note, field: "note", profile: .preview, truncatedFields: &truncated)
        text = boundedField(item.text, field: "text", profile: .preview, truncatedFields: &truncated)
        modifiedAt = item.modifiedAt
        textApproximate = item.textApproximate
        presentationColor = item.presentationColor.map(PDFHighlightPresentationColorResult.init)
        truncatedFields = Array(Set(truncated)).sorted()
    }
}

struct PDFHighlightPresentationColorResult: Codable, Equatable, Sendable {
    let name: String
    let approximate: Bool

    init(_ color: PDFAgentPresentationColor) {
        name = color.name.rawValue
        approximate = color.approximate
    }
}

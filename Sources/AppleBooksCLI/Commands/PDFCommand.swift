import AppleBooksCore
import ArgumentParser
import CoreGraphics
import Foundation

struct PDFCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pdf",
        abstract: "Inspect PDF inventory and extract PDFKit highlights.",
        subcommands: [PDFListCommand.self, PDFHighlightsCommand.self]
    )
}

struct PDFListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List canonical Apple Books and fallback PDF sources."
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
        abstract: "Extract highlights from exactly one PDF source."
    )

    @Option(name: .customLong("book"), help: "Use an exact Apple Books asset ID.")
    var book: String?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Use an explicit local book primary key.")
    var bookPK: Int64?

    @Option(name: .customLong("pdf"), help: "Use an opaque PDF source ID returned by `pdf list`.")
    var pdfSourceID: String?

    @Option(name: .long, help: "Use an explicit absolute PDF path.")
    var path: String?

    @Option(name: .long, parsing: .unconditional, help: "Per-PDF worker timeout in seconds.")
    var timeout: Double = AppleBooks.defaultPDFWorkerTimeout

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(
        workerURL injectedWorkerURL: URL? = nil,
        using injectedBooks: AppleBooks? = nil
    ) throws -> PDFHighlightsResult {
        let selection = try parseSelection()
        guard timeout.isFinite, timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }

        let books: AppleBooks
        if let injectedBooks {
            books = injectedBooks
        } else {
            let workerURL = try injectedWorkerURL ?? installedPDFWorkerURL()
            books = try CLIContext(global: global).makeAppleBooks(
                dependencies: [.libraryRead, .pdfWorker],
                pdfWorkerURL: workerURL,
                pdfWorkerTimeout: timeout
            )
        }

        return try CLIOperation.run {
            let source: PDFSource
            switch selection {
            case let .book(selector):
                guard let selectedBook = try selector.resolveSemanticDetail(in: books) else {
                    throw CLIError.notFound("Book not found.")
                }
                guard let resolved = try books.semanticPDFSource(forBookLocalPK: selectedBook.localPK) else {
                    throw CLIError.unavailable("Selected book does not have an available PDF source.")
                }
                source = resolved
            case let .sourceID(sourceID):
                guard let resolved = try books.semanticPDFSource(sourceID: sourceID) else {
                    throw CLIError.notFound("PDF source not found. Run `applebookscli pdf list` again.")
                }
                source = resolved
            case let .path(fileURL):
                guard let resolved = try books.semanticPDFSource(fileURL: fileURL) else {
                    throw CLIError.unavailable("Selected PDF source is unavailable.")
                }
                source = resolved
            }
            return PDFHighlightsResult(try books.pdfHighlights(source: source))
        }
    }

    private func parseSelection() throws -> PDFCLISelection {
        let bookSelector = try parseOptionalBookSelector(
            assetID: book,
            localPK: bookPK,
            localPKOptionName: "--book-pk"
        )
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
        let selectorCount = [bookSelector != nil, sourceID != nil, path != nil].count(where: { $0 })
        guard selectorCount == 1 else {
            throw ValidationError("Provide exactly one of --book/--book-pk, --pdf, or --path.")
        }
        if let bookSelector { return .book(bookSelector) }
        if let sourceID { return .sourceID(sourceID) }
        guard let path else { throw ValidationError("PDF selector is missing.") }
        guard path.hasPrefix("/") else {
            throw ValidationError("--path must be an absolute normalized path.")
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL
        guard fileURL.path == path else {
            throw ValidationError("--path must be an absolute normalized path.")
        }
        return .path(fileURL)
    }
}

private enum PDFCLISelection {
    case book(BookSelector)
    case sourceID(PDFSourceID)
    case path(URL)
}

struct PDFSourceListResult: Codable, Equatable, Sendable {
    let items: [PDFInventoryResult]
    let nextCursor: String?
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

struct PDFSourceResult: Codable, Equatable, Sendable {
    let bookAssetID: String?
    let pdfSourceID: String?
    let title: String
    let provenance: String

    init(_ source: PDFSource) {
        let summaryAssetID = source.bookSummary?.assetID ?? source.book?.assetID
        bookAssetID = source.pdfSourceID == nil && PublicStableTokenPolicy.isEligible(summaryAssetID) ? summaryAssetID : nil
        pdfSourceID = source.pdfSourceID
        title = source.displayTitle
        provenance = source.provenance.rawValue
    }

}

private func validatePDFPageInput(limit: Int?, cursor: String?) throws {
    try CLIOperation.run {
        _ = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
    }
}

struct PDFHighlightsResult: Codable, Equatable, Sendable {
    let documents: [PDFDocumentHighlightsResult]
    let failures: [PDFFailureResult]
    let attemptedCount: Int
    let succeededCount: Int
    let noHighlightsCount: Int
    let failedCount: Int
    let timeoutCount: Int

    init(_ result: PDFHighlightServiceResult) {
        documents = result.documents.map(PDFDocumentHighlightsResult.init)
        failures = result.failures.map(PDFFailureResult.init)
        attemptedCount = result.attemptedCount
        succeededCount = result.succeededCount
        noHighlightsCount = result.noHighlightsCount
        failedCount = result.failedCount
        timeoutCount = result.timeoutCount
    }

}

struct PDFDocumentHighlightsResult: Codable, Equatable, Sendable {
    let source: PDFSourceResult
    let highlights: [PDFHighlightResult]

    init(_ document: PDFDocumentHighlights) {
        source = PDFSourceResult(document.source)
        highlights = document.highlights.map(PDFHighlightResult.init)
    }
}

struct PDFHighlightResult: Codable, Equatable, Sendable {
    let page: Int
    let traversalIndex: Int
    let bounds: PDFRectResult
    let quadrilateralPoints: [PDFPointResult]
    let note: String?
    let pdfKitRGBA: [Double]?
    let presentationColor: PDFColorResult?
    let modifiedAt: Date?
    let text: String?
    let textSource: String?
    let textIsApproximate: Bool
    let textUnavailableReason: String?

    init(_ highlight: PDFHighlight) {
        page = highlight.page
        traversalIndex = highlight.traversalIndex
        bounds = PDFRectResult(highlight.bounds)
        quadrilateralPoints = highlight.quadrilateralPoints.map(PDFPointResult.init)
        note = highlight.note
        pdfKitRGBA = highlight.pdfKitRGBA
        presentationColor = highlight.presentationColor.map(PDFColorResult.init)
        modifiedAt = highlight.modifiedAt
        text = highlight.text
        textSource = highlight.textSource?.rawValue
        textIsApproximate = highlight.textIsApproximate
        textUnavailableReason = highlight.textUnavailableReason?.rawValue
    }
}

struct PDFRectResult: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.size.width)
        height = Double(rect.size.height)
    }
}

struct PDFPointResult: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        x = Double(point.x)
        y = Double(point.y)
    }
}

struct PDFColorResult: Codable, Equatable, Sendable {
    let color: String
    let distance: Double
    let isApproximate: Bool

    init(_ match: PDFColorMatch) {
        color = match.color.rawValue
        distance = match.distance
        isApproximate = match.isApproximate
    }
}

struct PDFFailureResult: Codable, Equatable, Sendable {
    let source: PDFSourceResult
    let reason: String
    let detail: Int?

    init(_ failure: PDFHighlightServiceFailure) {
        source = PDFSourceResult(failure.source)
        switch failure.reason {
        case .timeout:
            reason = "timeout"
            detail = nil
        case .internalFailure:
            reason = "internalFailure"
            detail = nil
        case let .worker(error):
            switch error {
            case .launchFailed: (reason, detail) = ("launchFailed", nil)
            case .timedOut: (reason, detail) = ("timeout", nil)
            case let .stdoutLimitExceeded(capturedBytes): (reason, detail) = ("stdoutLimitExceeded", capturedBytes)
            case let .stderrLimitExceeded(capturedBytes): (reason, detail) = ("stderrLimitExceeded", capturedBytes)
            case .pipeReadFailed: (reason, detail) = ("pipeReadFailed", nil)
            case let .nonzeroExit(code): (reason, detail) = ("nonzeroExit", Int(code))
            case let .signalTerminated(signal): (reason, detail) = ("signalTerminated", Int(signal))
            case .malformedResponse: (reason, detail) = ("malformedResponse", nil)
            case let .workerFailure(code): (reason, detail) = (code.rawValue, nil)
            }
        }
    }
}

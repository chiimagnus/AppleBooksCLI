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

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> PDFSourceListResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return PDFSourceListResult(items: try books.pdfSources().map(PDFSourceResult.init))
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

    @Option(name: .long, help: "Use an explicit absolute PDF path.")
    var path: String?

    @Option(name: .long, parsing: .unconditional, help: "Per-PDF worker timeout in seconds.")
    var timeout: Double = AppleBooks.defaultPDFWorkerTimeout

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(workerURL injectedWorkerURL: URL? = nil) throws -> PDFHighlightsResult {
        let selection = try parseSelection()
        guard timeout.isFinite, timeout > 0 else {
            throw ValidationError("--timeout must be greater than zero.")
        }

        let workerURL = try injectedWorkerURL ?? installedPDFWorkerURL()
        guard FileManager.default.isExecutableFile(atPath: workerURL.path) else {
            throw CLIError.unavailable("PDF worker is unavailable.")
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(
                pdfWorkerURL: workerURL,
                pdfWorkerTimeout: timeout
            )
            let source: PDFSource
            switch selection {
            case let .book(selector):
                guard let selectedBook = try selector.resolve(in: books) else {
                    throw CLIError.notFound("Book not found.")
                }
                guard let resolved = try books.pdfSource(forBookLocalPK: selectedBook.localPK) else {
                    throw CLIError.unavailable("Selected book does not have an available PDF source.")
                }
                source = resolved
            case let .path(fileURL):
                guard let resolved = try books.pdfSource(fileURL: fileURL) else {
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
        if bookSelector != nil, path != nil {
            throw ValidationError("--book/--book-pk and --path are mutually exclusive.")
        }
        if let bookSelector { return .book(bookSelector) }
        guard let path else {
            throw ValidationError("Provide exactly one of --book, --book-pk, or --path.")
        }
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
    case path(URL)
}

struct PDFSourceListResult: Codable, Equatable, Sendable {
    let items: [PDFSourceResult]

    var humanDescription: String {
        (["total: \(items.count)"] + items.map(\.humanSummary)).joined(separator: "\n")
    }
}

struct PDFSourceResult: Codable, Equatable, Sendable {
    let filePath: String
    let displayTitle: String
    let provenance: String
    let book: BookResult?

    init(_ source: PDFSource) {
        filePath = source.fileURL.path
        displayTitle = source.displayTitle
        provenance = source.provenance.rawValue
        book = source.book.map { BookResult(book: $0) }
    }

    var humanSummary: String {
        "\(provenance)\t\(book?.assetID ?? "-")\t\(displayTitle)\t\(filePath)"
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

    var humanDescription: String {
        var lines = [
            "attempted: \(attemptedCount)",
            "succeeded: \(succeededCount)",
            "failed: \(failedCount)",
            "timeouts: \(timeoutCount)",
        ]
        for document in documents {
            lines.append("\(document.source.displayTitle): \(document.highlights.count) highlights")
        }
        return lines.joined(separator: "\n")
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

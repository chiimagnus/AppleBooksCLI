import AppleBooksCore
import ArgumentParser
import Foundation

enum ExportFormatArgument: String, ExpressibleByArgument, Sendable {
    case json
    case markdown

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        }
    }
}

enum ExportSourceArgument: String, ExpressibleByArgument, Sendable {
    case epub
    case pdf
    case all

    var coreValue: ExportSourceScope { ExportSourceScope(rawValue: rawValue)! }
}

enum ExportKindArgument: String, ExpressibleByArgument, Sendable {
    case highlight
    case note
    case bookmark

    var coreValue: ExportPresentationKind { ExportPresentationKind(rawValue: rawValue)! }
}

enum ExportColorArgument: String, ExpressibleByArgument, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple

    var coreValue: ExportPresentationColor { ExportPresentationColor(rawValue: rawValue)! }
}

enum ExportOrderArgument: String, ExpressibleByArgument, Sendable {
    case source
    case reading

    var coreValue: ExportOrder { ExportOrder(rawValue: rawValue)! }
}

enum ExportGroupingArgument: String, ExpressibleByArgument, Sendable {
    case single
    case perBook = "per-book"

    var coreValue: ExportFileGrouping {
        switch self {
        case .single: .single
        case .perBook: .perBook
        }
    }
}

enum ExportCoverArgument: String, ExpressibleByArgument, Sendable {
    case none
    case inline
    case file

    var coreValue: ExportCoverMode { ExportCoverMode(rawValue: rawValue)! }
}

enum ExportOverwriteArgument: String, ExpressibleByArgument, Sendable {
    case never
    case smart
    case always

    var coreValue: OverwritePolicy { OverwritePolicy(rawValue: rawValue)! }
}

struct ExportCLIRequest: Equatable, Sendable {
    let format: ExportFormatArgument
    let options: ExportOptions
    let overwrite: OverwritePolicy
    let outputURL: URL

    var producesMultipleFiles: Bool {
        options.grouping == .perBook || (format == .markdown && options.cover == .file)
    }
}

enum ExportRunDisposition: String, Codable, Equatable, Sendable {
    case file
    case directory
}

struct ExportRunResult: Codable, Equatable, Sendable {
    let destination: String
    let disposition: ExportRunDisposition
    let documentCount: Int
    let warningCount: Int
    let complete: Bool
}

struct ExportCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export Apple Books annotations and PDF highlights."
    )

    @Option(name: .long, help: "Export format: json or markdown.")
    var format: ExportFormatArgument

    @Option(name: .long, help: "Select an exact Apple Books asset ID. Repeatable.")
    var book: [String] = []

    @Option(name: .customLong("book-pk"), help: "Select an explicit local book primary key. Repeatable.")
    var bookPK: [Int64] = []

    @Option(name: .long, help: "Source scope: epub, pdf, or all.")
    var source: ExportSourceArgument?

    @Option(name: .long, help: "Presentation kind: highlight, note, or bookmark. Repeatable.")
    var kind: [ExportKindArgument] = []

    @Option(name: .long, help: "Presentation color. Repeatable.")
    var color: [ExportColorArgument] = []

    @Flag(name: .long, help: "Keep only underlined presentations.")
    var underline = false

    @Option(name: .long, help: "Stable ordering: source or reading.")
    var order: ExportOrderArgument?

    @Option(name: .customLong("skip-first"), parsing: .unconditional, help: "Skip the first N records per final sorted document.")
    var skipFirst: Int?

    @Option(name: .long, help: "File grouping: single or per-book.")
    var grouping: ExportGroupingArgument?

    @Flag(name: .customLong("include-epub-metadata"), help: "Include EPUB package metadata when available.")
    var includeEPUBMetadata = false

    @Option(name: .long, help: "Cover mode: none, inline, or file.")
    var cover: ExportCoverArgument?

    @Option(name: .long, help: "Existing-file policy: never, smart, or always.")
    var overwrite: ExportOverwriteArgument?

    @Option(name: .long, help: "Write the export artifact to this file or directory.")
    var output: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func makeRequest() throws -> ExportCLIRequest {
        for localPK in bookPK {
            try LocalPKPolicy.validateInput(localPK, optionName: "--book-pk")
        }
        let defaults = try CLIOperation.run { try ExportOptions() }
        let selectors = book.map(ExportBookSelector.assetID) + bookPK.map(ExportBookSelector.localPK)
        let kinds = kind.isEmpty ? defaults.kinds : Set(kind.map(\.coreValue))
        let colors: Set<ExportPresentationColor>? = color.isEmpty ? defaults.colors : Set(color.map(\.coreValue))
        let resolvedSource = source?.coreValue ?? defaults.source
        let resolvedOrder = order?.coreValue ?? defaults.order
        let resolvedSkip = skipFirst ?? defaults.skipFirstPerBook
        let resolvedGrouping = grouping?.coreValue ?? defaults.grouping
        let resolvedCover = cover?.coreValue ?? defaults.cover

        let options = try CLIOperation.run {
            try ExportOptions(
                source: resolvedSource,
                bookSelectors: selectors,
                kinds: kinds,
                colors: colors,
                underline: underline ? true : defaults.underline,
                order: resolvedOrder,
                skipFirstPerBook: resolvedSkip,
                grouping: resolvedGrouping,
                includeEPUBMetadata: includeEPUBMetadata,
                cover: resolvedCover
            )
        }

        try validateFormatSpecificOptions(options: options)

        let overwritePolicy = overwrite?.coreValue ?? .never
        guard let output else {
            throw ValidationError("Export requires --output.")
        }
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        let request = ExportCLIRequest(
            format: format,
            options: options,
            overwrite: overwritePolicy,
            outputURL: outputURL
        )
        try validateOutputContract(request)
        return request
    }

    @discardableResult
    func execute(
        using injectedBooks: AppleBooks? = nil,
        exportedAt: Date = Date(),
        workerURLProvider: () throws -> URL = { try installedPDFWorkerURL() }
    ) throws -> ExportRunResult {
        let request = try makeRequest()
        return try CLIOperation.run {
            let books = try injectedBooks ?? makeAppleBooks(
                for: request.options,
                workerURLProvider: workerURLProvider
            )
            let bundle = try books.exportBundle(options: request.options)
            return try write(
                bundle,
                request: request,
                outputURL: request.outputURL,
                exportedAt: exportedAt
            )
        }
    }

    private func validateFormatSpecificOptions(options: ExportOptions) throws {
        if options.cover == .file, format != .markdown {
            throw ValidationError("--cover file requires --format markdown.")
        }
    }

    private func validateOutputContract(_ request: ExportCLIRequest) throws {
        guard request.outputURL.lastPathComponent.isEmpty == false else {
            throw ValidationError("--output must name a file or directory.")
        }
    }

    private func makeAppleBooks(
        for options: ExportOptions,
        workerURLProvider: () throws -> URL
    ) throws -> AppleBooks {
        let context = CLIContext(global: global)
        var dependencies: AppleBooksDependencies = [.libraryRead]

        if options.bookSelectors.isEmpty {
            switch options.source {
            case .epub:
                dependencies.formUnion([.annotationsRead, .configuration])
            case .pdf:
                dependencies.insert(.pdfWorker)
            case .all:
                dependencies.formUnion([.annotationsRead, .configuration, .pdfWorker])
            }
        } else {
            let probe = try context.makeAppleBooks(dependencies: .libraryRead)
            for selector in options.bookSelectors {
                switch selector {
                case let .assetID(assetID):
                    let current = try probe.book(assetID: assetID)
                    if current?.contentType == 3 {
                        if options.source != .epub { dependencies.insert(.pdfWorker) }
                    } else if options.source != .pdf {
                        dependencies.formUnion([.annotationsRead, .configuration])
                    }
                case let .localPK(localPK):
                    guard let current = try probe.book(localPK: localPK) else { continue }
                    if current.contentType == 3 {
                        if options.source != .epub { dependencies.insert(.pdfWorker) }
                    } else if options.source != .pdf {
                        dependencies.formUnion([.annotationsRead, .configuration])
                    }
                case .pdfFile:
                    if options.source != .epub { dependencies.insert(.pdfWorker) }
                }
            }
        }

        let workerURL = dependencies.contains(.pdfWorker) ? try workerURLProvider() : nil
        return try context.makeAppleBooks(
            dependencies: dependencies,
            pdfWorkerURL: workerURL
        )
    }

    private func renderSingle(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        exportedAt: Date
    ) throws -> String {
        switch request.format {
        case .json:
            return String(decoding: try JSONExporter.render(bundle, exportedAt: exportedAt), as: UTF8.self)
        case .markdown:
            return try MarkdownAnnotationExporter.render(bundle, coverMode: request.options.cover)
        }
    }

    private func write(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputURL: URL,
        exportedAt: Date
    ) throws -> ExportRunResult {
        if request.producesMultipleFiles {
            return try writeMultiple(
                bundle,
                request: request,
                outputDirectory: outputURL,
                exportedAt: exportedAt
            )
        }

        let parent = outputURL.deletingLastPathComponent().standardizedFileURL
        let writer = try ExportFileWriter(outputRoot: parent)
        if request.format == .markdown {
            let result = try writer.writeMarkdown(
                bundle,
                layout: .single(fileName: outputURL.lastPathComponent),
                coverMode: request.options.cover,
                overwrite: request.overwrite
            )
            return ExportRunResult(
                destination: outputURL.path,
                disposition: .file,
                documentCount: result.documentFileCount,
                warningCount: bundle.warnings.count,
                complete: bundle.sourceTotals.pdfFailedDocumentCount == 0
            )
        }

        let data = try renderData(bundle, request: request, exportedAt: exportedAt)
        let file = try writer.write(
            data,
            fileName: outputURL.lastPathComponent,
            overwrite: request.overwrite
        )
        return ExportRunResult(
            destination: file.destination.path,
            disposition: .file,
            documentCount: 1,
            warningCount: bundle.warnings.count,
            complete: bundle.sourceTotals.pdfFailedDocumentCount == 0
        )
    }

    private func writeMultiple(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputDirectory: URL,
        exportedAt: Date
    ) throws -> ExportRunResult {
        let result: ExportDirectoryWriteResult
        let writer = try ExportFileWriter(outputRoot: outputDirectory)
        if request.format == .markdown {
            let layout: ExportFileLayout = request.options.grouping == .perBook
                ? .perBook
                : .single(fileName: "apple-books-export.md")
            result = try writer.writeMarkdown(
                bundle,
                layout: layout,
                coverMode: request.options.cover,
                overwrite: request.overwrite
            )
        } else {
            result = try writer.writeDocuments(
                bundle,
                fileExtension: request.format.fileExtension,
                overwrite: request.overwrite
            ) { group in
                try renderDocumentData(group, bundle: bundle, request: request, exportedAt: exportedAt)
            }
        }
        return ExportRunResult(
            destination: outputDirectory.path,
            disposition: .directory,
            documentCount: result.documentFileCount,
            warningCount: bundle.warnings.count,
            complete: bundle.sourceTotals.pdfFailedDocumentCount == 0
        )
    }

    private func renderData(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        exportedAt: Date
    ) throws -> Data {
        switch request.format {
        case .json:
            try JSONExporter.render(bundle, exportedAt: exportedAt)
        case .markdown:
            Data(try renderSingle(bundle, request: request, exportedAt: exportedAt).utf8)
        }
    }

    private func renderDocumentData(
        _ group: ExportGroup,
        bundle: ExportBundle,
        request: ExportCLIRequest,
        exportedAt: Date
    ) throws -> Data {
        switch request.format {
        case .json:
            try JSONExporter.renderDocument(group, from: bundle, exportedAt: exportedAt)
        case .markdown:
            throw CLIError.internalFailure
        }
    }


}

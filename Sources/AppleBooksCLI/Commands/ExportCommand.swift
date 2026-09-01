import AppleBooksCore
import ArgumentParser
import Foundation

enum ExportFormatArgument: String, ExpressibleByArgument, Sendable {
    case json
    case csv
    case markdown
    case html

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .csv: "csv"
        case .markdown: "md"
        case .html: "html"
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

enum ExportProfileArgument: String, ExpressibleByArgument, Sendable {
    case plain
    case obsidian
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
    let profile: MarkdownProfile
    let overwrite: OverwritePolicy
    let outputURL: URL?

    var producesMultipleFiles: Bool {
        options.grouping == .perBook ||
            (format == .markdown && (options.cover == .file || profile.options.authorPages))
    }
}

enum ExportRunResult: Equatable, Sendable {
    case stdout
    case files(documentFileCount: Int, files: [URL], warningCount: Int)
}

struct ExportCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export Apple Books annotations and PDF highlights."
    )

    @Option(name: .long, help: "Export format: json, csv, markdown, or html.")
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

    @Flag(name: .customLong("complete-notes"), help: "Enable fail-closed complete note archive validation.")
    var completeNotes = false

    @Option(name: .long, help: "Markdown profile: plain or obsidian.")
    var profile: ExportProfileArgument?

    @Option(name: .long, help: "Existing-file policy: never, smart, or always.")
    var overwrite: ExportOverwriteArgument?

    @Flag(name: .customLong("extended-frontmatter"), help: "Emit extended Obsidian YAML frontmatter.")
    var extendedFrontmatter = false

    @Flag(name: .customLong("body-metadata"), help: "Emit additional metadata in the Markdown body.")
    var bodyMetadata = false

    @Option(name: .long, help: "Add a custom Markdown tag. Repeatable.")
    var tag: [String] = []

    @Flag(name: .customLong("chapter-headings"), help: "Group Markdown annotations under chapter headings.")
    var chapterHeadings = false

    @Flag(name: .customLong("annotation-dates"), help: "Include annotation dates in Markdown.")
    var annotationDates = false

    @Flag(name: .customLong("annotation-styles"), help: "Include annotation style and underline metadata in Markdown.")
    var annotationStyles = false

    @Flag(name: .customLong("reading-progress"), help: "Include reading progress in Markdown.")
    var readingProgress = false

    @Flag(name: .long, help: "Include citation blocks in Markdown.")
    var citation = false

    @Flag(name: .customLong("author-pages"), help: "Create author pages and link exported documents to them.")
    var authorPages = false

    @Flag(name: .customLong("group-null-location-fragments"), help: "Group consecutive no-location Markdown fragments for presentation.")
    var groupNullLocationFragments = false

    @Option(name: .long, help: "Write to this file or directory instead of stdout.")
    var output: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        _ = try execute(output: output)
    }

    func makeRequest() throws -> ExportCLIRequest {
        if global.json {
            throw ValidationError("`export` does not accept --json; use --format json.")
        }
        if completeNotes, book.isEmpty == false || bookPK.isEmpty == false || kind.isEmpty == false ||
            color.isEmpty == false || underline {
            throw ValidationError("--complete-notes cannot be combined with book, kind, color, or underline filters.")
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
                cover: resolvedCover,
                completeNotes: completeNotes
            )
        }

        let markdownProfile = try makeMarkdownProfile()
        try validateFormatSpecificOptions(options: options, profile: markdownProfile)

        let overwritePolicy = overwrite?.coreValue ?? .never
        let outputURL = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let request = ExportCLIRequest(
            format: format,
            options: options,
            profile: markdownProfile,
            overwrite: overwritePolicy,
            outputURL: outputURL
        )
        try validateOutputContract(request)
        return request
    }

    @discardableResult
    func execute(
        using injectedBooks: AppleBooks? = nil,
        output cliOutput: CLIOutput = .standard,
        exportedAt: Date = Date()
    ) throws -> ExportRunResult {
        let request = try makeRequest()
        return try CLIOperation.run {
            let books = try injectedBooks ?? makeAppleBooks(for: request.options.source)
            let bundle = try books.exportBundle(options: request.options)
            if bundle.warnings.isEmpty == false {
                cliOutput.stderr("Warning: export completed with \(bundle.warnings.count) source warning(s).")
            }
            guard let outputURL = request.outputURL else {
                cliOutput.stdout(try renderSingle(bundle, request: request, exportedAt: exportedAt))
                return .stdout
            }
            return try write(bundle, request: request, outputURL: outputURL, exportedAt: exportedAt, cliOutput: cliOutput)
        }
    }

    private func makeMarkdownProfile() throws -> MarkdownProfile {
        let hasMarkdownOptions = extendedFrontmatter || bodyMetadata || tag.isEmpty == false || chapterHeadings ||
            annotationDates || annotationStyles || readingProgress || citation || authorPages || groupNullLocationFragments
        if format != .markdown, profile != nil || hasMarkdownOptions {
            throw ValidationError("Markdown profile options require --format markdown.")
        }

        let selected = profile ?? .plain
        if selected == .plain, hasMarkdownOptions {
            throw ValidationError("Obsidian-specific Markdown options require --profile obsidian.")
        }
        guard selected == .obsidian else { return .plain }

        return MarkdownProfile(
            syntax: .obsidian,
            options: ObsidianMarkdownOptions(
                extendedFrontmatter: extendedFrontmatter,
                bodyMetadata: bodyMetadata,
                includeTags: false,
                customTags: tag,
                chapterHeadings: chapterHeadings,
                annotationDates: annotationDates,
                annotationStyle: annotationStyles,
                readingProgress: readingProgress,
                citation: citation,
                authorLinks: authorPages,
                authorPages: authorPages,
                groupConsecutiveNullLocationFragments: groupNullLocationFragments
            )
        )
    }

    private func validateFormatSpecificOptions(options: ExportOptions, profile: MarkdownProfile) throws {
        if options.cover == .file, format != .markdown {
            throw ValidationError("--cover file requires --format markdown.")
        }
        if format != .markdown, profile != .plain {
            throw ValidationError("--profile is available only for Markdown export.")
        }
    }

    private func validateOutputContract(_ request: ExportCLIRequest) throws {
        if request.outputURL == nil {
            if request.producesMultipleFiles {
                throw ValidationError("Multi-file export requires --output <directory>.")
            }
            if overwrite != nil {
                throw ValidationError("--overwrite requires --output.")
            }
        }
        if request.options.completeNotes, request.producesMultipleFiles, request.overwrite != .never {
            throw ValidationError("Multi-file --complete-notes export requires --overwrite never and a new output directory.")
        }
    }

    private func makeAppleBooks(for source: ExportSourceScope) throws -> AppleBooks {
        let context = CLIContext(global: global)
        guard source != .epub else { return try context.makeAppleBooks() }
        return try context.makeAppleBooks(pdfWorkerURL: try installedPDFWorkerURL())
    }

    private func renderSingle(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        exportedAt: Date
    ) throws -> String {
        switch request.format {
        case .json:
            return String(decoding: try JSONExporter.render(bundle, exportedAt: exportedAt), as: UTF8.self)
        case .csv:
            return String(decoding: CSVExporter.render(bundle), as: UTF8.self)
        case .markdown:
            return try MarkdownAnnotationExporter.render(
                bundle,
                profile: request.profile,
                coverMode: request.options.cover
            )
        case .html:
            return HTMLExporter.render(bundle)
        }
    }

    private func write(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputURL: URL,
        exportedAt: Date,
        cliOutput: CLIOutput
    ) throws -> ExportRunResult {
        if request.producesMultipleFiles {
            return try writeMultiple(
                bundle,
                request: request,
                outputDirectory: outputURL,
                exportedAt: exportedAt,
                cliOutput: cliOutput
            )
        }

        let parent = outputURL.deletingLastPathComponent().standardizedFileURL
        let writer = try ExportFileWriter(outputRoot: parent)
        if request.format == .markdown {
            let result = try writer.writeMarkdown(
                bundle,
                layout: .single(fileName: outputURL.lastPathComponent),
                profile: request.profile,
                coverMode: request.options.cover,
                overwrite: request.overwrite
            )
            return makeRunResult(result, cliOutput: cliOutput)
        }

        let data = try renderData(bundle, request: request, exportedAt: exportedAt)
        let file = try writer.write(
            data,
            fileName: outputURL.lastPathComponent,
            overwrite: request.overwrite
        )
        return .files(documentFileCount: 1, files: [file.destination], warningCount: 0)
    }

    private func writeMultiple(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputDirectory: URL,
        exportedAt: Date,
        cliOutput: CLIOutput
    ) throws -> ExportRunResult {
        let result: ExportDirectoryWriteResult
        if request.format == .markdown {
            let layout: ExportFileLayout = request.options.grouping == .perBook
                ? .perBook
                : .single(fileName: "apple-books-export.md")
            if request.options.completeNotes {
                result = try ExportFileWriter.writeCompleteNoteArchiveMarkdown(
                    bundle,
                    to: outputDirectory,
                    layout: layout,
                    profile: request.profile,
                    coverMode: request.options.cover
                )
            } else {
                let writer = try ExportFileWriter(outputRoot: outputDirectory)
                result = try writer.writeMarkdown(
                    bundle,
                    layout: layout,
                    profile: request.profile,
                    coverMode: request.options.cover,
                    overwrite: request.overwrite
                )
            }
        } else if request.options.completeNotes {
            result = try ExportFileWriter.writeCompleteNoteArchiveDocuments(
                bundle,
                to: outputDirectory,
                fileExtension: request.format.fileExtension
            ) { group in
                try renderDocumentData(group, bundle: bundle, request: request, exportedAt: exportedAt)
            }
        } else {
            let writer = try ExportFileWriter(outputRoot: outputDirectory)
            result = try writer.writeDocuments(
                bundle,
                fileExtension: request.format.fileExtension,
                overwrite: request.overwrite
            ) { group in
                try renderDocumentData(group, bundle: bundle, request: request, exportedAt: exportedAt)
            }
        }
        return makeRunResult(result, cliOutput: cliOutput)
    }

    private func renderData(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        exportedAt: Date
    ) throws -> Data {
        switch request.format {
        case .json:
            try JSONExporter.render(bundle, exportedAt: exportedAt)
        case .csv:
            CSVExporter.render(bundle)
        case .markdown:
            Data(try renderSingle(bundle, request: request, exportedAt: exportedAt).utf8)
        case .html:
            Data(HTMLExporter.render(bundle).utf8)
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
        case .csv:
            CSVExporter.renderDocument(group)
        case .markdown:
            throw CLIError.internalFailure
        case .html:
            Data(HTMLExporter.renderDocument(group).utf8)
        }
    }

    private func makeRunResult(_ result: ExportDirectoryWriteResult, cliOutput: CLIOutput) -> ExportRunResult {
        if result.warnings.isEmpty == false {
            cliOutput.stderr("Warning: \(result.warnings.count) export sidecar(s) could not be written.")
        }
        return .files(
            documentFileCount: result.documentFileCount,
            files: result.files,
            warningCount: result.warnings.count
        )
    }
}

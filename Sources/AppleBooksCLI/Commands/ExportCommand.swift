import AppleBooksCore
import ArgumentParser
import Foundation

enum ExportFormatArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case json
    case markdown

    var fileExtension: String {
        switch self {
        case .json: "json"
        case .markdown: "md"
        }
    }
}

enum ExportColorArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple

    var coreValue: ExportPresentationColor { ExportPresentationColor(rawValue: rawValue)! }
}

enum ExportGroupingArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case single
    case perDocument = "per-document"

    var coreValue: ExportFileGrouping {
        switch self {
        case .single: .single
        case .perDocument: .perDocument
        }
    }
}

enum ExportOverwriteArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case never
    case always

    var coreValue: OverwritePolicy { OverwritePolicy(rawValue: rawValue)! }
}

struct ExportCLIRequest: Equatable, Sendable {
    let format: ExportFormatArgument
    let options: ExportOptions
    let overwrite: OverwritePolicy
    let outputURL: URL

    var producesMultipleFiles: Bool {
        options.grouping == .perDocument
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
    var warnings: [ExportRunWarning] = []
}

struct ExportRunWarning: Codable, Equatable, Sendable {
    let code: String
    let source: String
    let reason: String

    static let managedDirectoryPublishSyncFailed = Self(
        code: "export_directory_sync_failed",
        source: "export",
        reason: "managed_directory_parent_sync_failed"
    )

    static let oldExportCleanupFailed = Self(
        code: "old_export_cleanup_failed",
        source: "export",
        reason: "managed_directory_cleanup_failed"
    )
}

struct ExportCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export Apple Books EPUB annotations."
    )

    @Option(name: .long, help: "Export format: markdown (default) or archival json.")
    var format: ExportFormatArgument = .markdown

    @Option(name: .long, help: "Select an exact Apple Books asset ID. Repeatable.")
    var book: [String] = []

    @Option(name: .customLong("book-pk"), help: "Select an explicit local book primary key. Repeatable.")
    var bookPK: [Int64] = []

    @Option(name: .long, help: "Filter highlight presence: true or false.")
    var hasHighlight: AnnotationBooleanArgument?

    @Option(name: .long, help: "Filter note presence: true or false.")
    var hasNote: AnnotationBooleanArgument?

    @Option(name: .long, help: "Filter by annotation color. Repeatable.")
    var color: [ExportColorArgument] = []

    @Option(name: .long, help: "Filter underline state: true or false.")
    var underline: AnnotationBooleanArgument?

    @Option(name: .long, help: "File grouping: single or per-document.")
    var grouping: ExportGroupingArgument?

    @Option(name: .long, help: "Existing-target policy: never (default) or always. Per-document always replaces only AppleBooksCLI-managed directories.")
    var overwrite: ExportOverwriteArgument?

    @Option(name: .long, help: "Write the export artifact to this file or directory.")
    var output: String

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func makeRequest(currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)) throws -> ExportCLIRequest {
        for localPK in bookPK {
            try LocalPKPolicy.validateInput(localPK, optionName: "--book-pk")
        }
        let defaults = try CLIOperation.run { try ExportOptions() }
        let selectors = book.map(ExportBookSelector.assetID) + bookPK.map(ExportBookSelector.localPK)
        let colors: Set<ExportPresentationColor>? = color.isEmpty ? defaults.colors : Set(color.map(\.coreValue))
        let resolvedGrouping = grouping?.coreValue ?? defaults.grouping

        let options = try CLIOperation.run {
            try ExportOptions(
                bookSelectors: selectors,
                hasHighlight: hasHighlight?.value,
                hasNote: hasNote?.value,
                colors: colors,
                underline: underline?.value,
                grouping: resolvedGrouping
            )
        }

        let overwritePolicy = overwrite?.coreValue ?? .never
        let outputURL = try CLIOperation.run {
            try ExportFileWriter.destination(path: output, currentDirectory: currentDirectory)
        }
        let request = ExportCLIRequest(
            format: format,
            options: options,
            overwrite: overwritePolicy,
            outputURL: outputURL
        )
        return request
    }

    @discardableResult
    func execute(
        using injectedBooks: AppleBooks? = nil,
        exportedAt: Date = Date(),
        managedDirectorySyncParentAfterPublish: ((Int32) -> Bool)? = nil
    ) throws -> ExportRunResult {
        let request = try makeRequest()
        return try CLIOperation.run {
            let books = try injectedBooks ?? makeAppleBooks(for: request.options)
            return try write(
                books.exportBundle(options: request.options),
                request: request,
                outputURL: request.outputURL,
                exportedAt: exportedAt,
                managedDirectorySyncParentAfterPublish: managedDirectorySyncParentAfterPublish
            )
        }
    }

    private func makeAppleBooks(for options: ExportOptions) throws -> AppleBooks {
        let context = CLIContext(global: global)
        let probe = try context.makeAppleBooks(dependencies: .libraryRead)
        let dependencies = try probe.exportDependencies(options: options)
        return try context.makeAppleBooks(dependencies: dependencies)
    }

    private func write(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputURL: URL,
        exportedAt: Date,
        managedDirectorySyncParentAfterPublish: ((Int32) -> Bool)?
    ) throws -> ExportRunResult {
        if request.producesMultipleFiles {
            return try writeMultiple(
                bundle,
                request: request,
                outputDirectory: outputURL,
                exportedAt: exportedAt,
                syncParentAfterPublish: managedDirectorySyncParentAfterPublish
            )
        }

        let parent = outputURL.deletingLastPathComponent().standardizedFileURL
        let writer = try ExportFileWriter(outputRoot: parent)
        let file = try writer.writeIncrementally(
            fileName: outputURL.lastPathComponent,
            overwrite: request.overwrite
        ) { sink in
            switch request.format {
            case .json:
                try JSONExporter.stream(bundle, exportedAt: exportedAt, to: sink)
            case .markdown:
                try MarkdownAnnotationExporter.stream(bundle, to: sink)
            }
        }
        return ExportRunResult(
            destination: file.destination.path,
            disposition: .file,
            documentCount: 1,
            warningCount: 0
        )
    }

    private func writeMultiple(
        _ bundle: ExportBundle,
        request: ExportCLIRequest,
        outputDirectory: URL,
        exportedAt: Date,
        syncParentAfterPublish: ((Int32) -> Bool)?
    ) throws -> ExportRunResult {
        let parent = outputDirectory.deletingLastPathComponent().standardizedFileURL
        let writer = try ExportFileWriter(outputRoot: parent)
        let managed = try writer.writeManagedDirectoryIncrementally(
            destinationName: outputDirectory.lastPathComponent,
            bundle: bundle,
            fileExtension: request.format.fileExtension,
            overwrite: request.overwrite,
            syncParentAfterPublish: syncParentAfterPublish
        ) { group, sink in
            switch request.format {
            case .json:
                try JSONExporter.streamDocument(group, from: bundle, exportedAt: exportedAt, to: sink)
            case .markdown:
                try MarkdownAnnotationExporter.stream(group, to: sink)
            }
        }
        var additionalWarnings: [ExportRunWarning] = []
        if managed.publishSyncFailed {
            additionalWarnings.append(.managedDirectoryPublishSyncFailed)
        }
        if managed.cleanupFailed {
            additionalWarnings.append(.oldExportCleanupFailed)
        }
        var result = ExportRunResult(
            destination: outputDirectory.standardizedFileURL.path,
            disposition: .directory,
            documentCount: managed.documentCount,
            warningCount: additionalWarnings.count
        )
        result.warnings = additionalWarnings
        return result
    }


}

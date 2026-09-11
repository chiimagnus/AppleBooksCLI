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

enum ExportSourceArgument: String, ExpressibleByArgument, CaseIterable, Sendable {
    case epub
    case pdf
    case all

    var coreValue: ExportSourceScope { ExportSourceScope(rawValue: rawValue)! }
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
    static let maximumWarnings = 100

    let destination: String
    let disposition: ExportRunDisposition
    let documentCount: Int
    let warningCount: Int
    let complete: Bool
    var warnings: [ExportRunWarning] = []
    var warningsTruncated = false
}

struct ExportRunWarning: Codable, Equatable, Sendable {
    let code: String
    let source: String
    let sourceID: String?
    let reason: String

    static func summaries(
        _ warnings: [ExportWarning],
        additional: [Self] = []
    ) throws -> (items: [Self], truncated: Bool) {
        let additionalCount = min(additional.count, ExportRunResult.maximumWarnings)
        var items = Array(additional.prefix(additionalCount))
        items.reserveCapacity(min(warnings.count + additionalCount, ExportRunResult.maximumWarnings))
        let remaining = ExportRunResult.maximumWarnings - items.count
        for warning in warnings.prefix(remaining) {
            items.append(try Self(warning))
        }
        return (
            items,
            additional.count + warnings.count > ExportRunResult.maximumWarnings
        )
    }

    static let managedDirectoryPublishSyncFailed = Self(
        code: "export_directory_sync_failed",
        source: "export",
        sourceID: nil,
        reason: "managed_directory_parent_sync_failed"
    )

    static let oldExportCleanupFailed = Self(
        code: "old_export_cleanup_failed",
        source: "export",
        sourceID: nil,
        reason: "managed_directory_cleanup_failed"
    )

    private init(code: String, source: String, sourceID: String?, reason: String) {
        self.code = code
        self.source = source
        self.sourceID = sourceID
        self.reason = reason
    }

    private init(_ warning: ExportWarning) throws {
        switch warning {
        case .pdfUnavailable:
            code = "pdf_unavailable"
            source = "pdf"
            sourceID = nil
            reason = "worker_unavailable"
        case let .pdfFailure(failure):
            code = "pdf_read_failed"
            source = "pdf"
            guard let stableID = Self.stableSourceID(failure.source) else {
                throw CLIError.internalFailure
            }
            sourceID = stableID
            reason = Self.reason(failure.reason)
        }
    }

    private static func stableSourceID(_ source: PDFSource) -> String? {
        if let sourceID = source.pdfSourceID { return sourceID }
        if let assetID = source.book?.assetID ?? source.bookSummary?.assetID,
           PublicStableIdentityPolicy.isEligible(assetID) {
            return assetID
        }
        return nil
    }

    private static func reason(_ failure: PDFHighlightServiceFailureReason) -> String {
        switch failure {
        case .timeout:
            "timeout"
        case .internalFailure:
            "internal_failure"
        case let .worker(error):
            workerReason(error)
        }
    }

    private static func workerReason(_ error: PDFWorkerClientError) -> String {
        switch error {
        case .launchFailed: "worker_launch_failed"
        case .timedOut: "timeout"
        case .stdoutLimitExceeded: "worker_stdout_limit"
        case .stderrLimitExceeded: "worker_stderr_limit"
        case .pipeReadFailed: "worker_pipe_read_failed"
        case .nonzeroExit: "worker_nonzero_exit"
        case .signalTerminated: "worker_signal_terminated"
        case .malformedResponse: "worker_malformed_response"
        case let .workerFailure(code): workerFailureReason(code)
        }
    }

    private static func workerFailureReason(_ code: PDFWorkerErrorCode) -> String {
        switch code {
        case .malformedRequest: "worker_malformed_request"
        case .requestTooLarge: "worker_request_too_large"
        case .unsupportedVersion: "worker_unsupported_version"
        case .invalidPath: "worker_invalid_path"
        case .unsupportedFormat: "worker_unsupported_format"
        case .unsafeFile: "worker_unsafe_file"
        case .staleSource: "worker_stale_source"
        case .unreadableDocument: "worker_unreadable_document"
        case .pageUnavailable: "worker_page_unavailable"
        case .internalFailure: "worker_internal_failure"
        }
    }
}

struct ExportCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export Apple Books annotations and PDF highlights."
    )

    @Option(name: .long, help: "Export format: markdown (default) or archival json.")
    var format: ExportFormatArgument = .markdown

    @Option(name: .long, help: "Select an exact Apple Books asset ID. Repeatable.")
    var book: [String] = []

    @Option(name: .customLong("book-pk"), help: "Select an explicit local book primary key. Repeatable.")
    var bookPK: [Int64] = []

    @Option(name: .long, help: "Select an opaque PDF source ID from pdf list. Repeatable.")
    var pdf: [String] = []

    @Option(name: .long, help: "Bulk source scope: epub, pdf, or all (default). Cannot combine with exact selectors.")
    var source: ExportSourceArgument?

    @Option(name: .long, help: "Filter highlight presence: true or false.")
    var hasHighlight: AnnotationBooleanArgument?

    @Option(name: .long, help: "Filter note presence: true or false.")
    var hasNote: AnnotationBooleanArgument?

    @Option(name: .long, help: "Filter by annotation color. PDF approximate colors do not match. Repeatable.")
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
            + pdf.map(ExportBookSelector.pdfSourceID)
        guard selectors.isEmpty || source == nil else {
            throw ValidationError("--source cannot be combined with exact selectors.")
        }
        let colors: Set<ExportPresentationColor>? = color.isEmpty ? defaults.colors : Set(color.map(\.coreValue))
        let resolvedSource = source?.coreValue ?? defaults.source
        let resolvedGrouping = grouping?.coreValue ?? defaults.grouping

        let options = try CLIOperation.run {
            try ExportOptions(
                source: resolvedSource,
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
        workerURLProvider: () throws -> URL = { try installedPDFWorkerURL() },
        managedDirectorySyncParentAfterPublish: ((Int32) -> Bool)? = nil
    ) throws -> ExportRunResult {
        let request = try makeRequest()
        return try CLIOperation.run {
            let books = try injectedBooks ?? makeAppleBooks(
                for: request.options,
                workerURLProvider: workerURLProvider
            )
            let bundle = try books.exportBundle(options: request.options)
            var result = try write(
                bundle,
                request: request,
                outputURL: request.outputURL,
                exportedAt: exportedAt,
                managedDirectorySyncParentAfterPublish: managedDirectorySyncParentAfterPublish
            )
            let warningSummary = try ExportRunWarning.summaries(
                bundle.warnings,
                additional: result.warnings
            )
            result.warnings = warningSummary.items
            result.warningsTruncated = warningSummary.truncated
            return result
        }
    }

    private func makeAppleBooks(
        for options: ExportOptions,
        workerURLProvider: () throws -> URL
    ) throws -> AppleBooks {
        let context = CLIContext(global: global)
        let probe = try context.makeAppleBooks(dependencies: .libraryRead)
        var dependencies = try probe.exportDependencies(options: options)
        var workerURL: URL?
        if dependencies.contains(.pdfWorker) {
            do {
                workerURL = try workerURLProvider()
            } catch {
                guard options.bookSelectors.isEmpty, options.source == .all else { throw error }
                dependencies.remove(.pdfWorker)
            }
        }
        return try context.makeAppleBooks(
            dependencies: dependencies,
            pdfWorkerURL: workerURL
        )
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
            warningCount: bundle.warnings.count,
            complete: bundle.complete
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
            warningCount: bundle.warnings.count + additionalWarnings.count,
            complete: bundle.complete
        )
        result.warnings = additionalWarnings
        return result
    }


}

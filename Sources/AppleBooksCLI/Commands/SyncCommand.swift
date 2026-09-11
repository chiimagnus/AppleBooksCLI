import AppleBooksCore
import ArgumentParser

struct SyncCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Send pending Apple Books changes and wait for acknowledgement on this Mac."
    )

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "sync" }

    func historyRequest() throws -> OperationHistoryRequest {
        OperationHistoryRequest()
    }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        let result = try execute(historySink: sink)
        try output.writeJSON(result)
    }

    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> CloudSyncCommandResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: [.collectionWrite, .annotationWrite])
            let summary = try books.syncPendingCloudChanges()
            historySink?.record(.sync(summary))
            return CloudSyncCommandResult(summary)
        }
    }
}

struct CloudSyncCommandResult: Codable, Equatable, Sendable {
    let status: CloudSyncStatus
    @ExplicitNullBool var acknowledged: Bool?
    let collectionPendingBefore: Int
    let annotationPendingBefore: Int
    let warningCodes: [String]

    init(_ summary: CloudSyncSummary) {
        status = summary.status
        _acknowledged = ExplicitNullBool(wrappedValue: summary.acknowledged)
        collectionPendingBefore = summary.collectionPendingBefore
        annotationPendingBefore = summary.annotationPendingBefore
        warningCodes = summary.warnings.map(\.rawValue)
    }
}

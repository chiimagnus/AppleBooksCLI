import AppleBooksCore
import ArgumentParser

struct SyncCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Flush all pending Apple Books cloud changes and wait for CloudKit acknowledgement."
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
    let acknowledged: Bool
    let collectionPendingBefore: Int
    let annotationPendingBefore: Int

    init(_ summary: CloudSyncSummary) {
        acknowledged = true
        collectionPendingBefore = summary.collectionPendingBefore
        annotationPendingBefore = summary.annotationPendingBefore
    }

}

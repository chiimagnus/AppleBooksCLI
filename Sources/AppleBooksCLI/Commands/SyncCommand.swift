import AppleBooksCore
import ArgumentParser

struct SyncCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Flush all pending Apple Books cloud changes and wait for CloudKit acknowledgement."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> CloudSyncCommandResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return CloudSyncCommandResult(try books.syncPendingCloudChanges())
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

    var humanDescription: String {
        [
            "acknowledged: true",
            "collection pending before: \(collectionPendingBefore)",
            "annotation pending before: \(annotationPendingBefore)",
        ].joined(separator: "\n")
    }
}

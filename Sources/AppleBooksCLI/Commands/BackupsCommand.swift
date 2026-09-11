import AppleBooksCore
import ArgumentParser
import Foundation

struct BackupsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backups",
        abstract: "List and restore guarded Apple Books library backups.",
        subcommands: [
            BackupsListCommand.self,
            BackupsRestoreCommand.self,
        ]
    )
}

struct BackupsListCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the newest 10 safe library recovery backups."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> BackupListResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .libraryBackup)
            return BackupListResult(items: try books.listLibraryBackups().map(BackupResult.init))
        }
    }
}

struct BackupsRestoreCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a library backup by its opaque backupID."
    )

    @Argument(help: "Exact opaque backupID for an existing library backup; it need not appear in the current newest-10 list.")
    var backupID: String

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "backups.restore" }

    func historyRequest() throws -> OperationHistoryRequest {
        guard LibraryBackup.isValidBackupID(backupID) else {
            throw CLIError.usageInvalid("Invalid backupID.")
        }
        return OperationHistoryRequest(selector: OperationHistorySelector(backupID: backupID))
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
    ) throws -> RestoreCommandResult {
        guard LibraryBackup.isValidBackupID(backupID) else {
            throw CLIError.usageInvalid("Invalid backupID.")
        }
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .libraryBackup)
            let restore = try books.restoreLibraryBackup(backupID: backupID)
            historySink?.record(.restore(restore))
            return try RestoreCommandResult(restore)
        }
    }
}

struct BackupListResult: Codable, Equatable, Sendable {
    let items: [BackupResult]

}

struct BackupResult: Codable, Equatable, Sendable {
    let backupID: String
    let createdAt: Date
    let sizeBytes: Int64

    init(_ backup: LibraryBackup) {
        backupID = backup.backupID
        createdAt = backup.createdAt
        sizeBytes = backup.sizeBytes
    }

}

enum RestoreCLIStatus: String, Codable, Equatable, Sendable {
    case restoredVerified = "restored_verified"
    case restoredUnverified = "restored_unverified"
}

struct RestoreCommandResult: Codable, Equatable, Sendable {
    let changed: Bool
    let status: RestoreCLIStatus
    let verified: Bool
    let restoredFromBackupID: String
    let safetyBackupID: String
    let warningCodes: [String]

    init(_ result: RestoreResult) throws {
        guard let restoredFromBackupID = result.restoredFromBackupID,
              let safetyBackupID = result.safetyBackupID else {
            throw CLIError.internalFailure
        }
        changed = result.restoreApplied
        status = result.verified ? .restoredVerified : .restoredUnverified
        verified = result.verified
        self.restoredFromBackupID = restoredFromBackupID
        self.safetyBackupID = safetyBackupID
        warningCodes = result.warnings.map(\.rawValue)
    }

}

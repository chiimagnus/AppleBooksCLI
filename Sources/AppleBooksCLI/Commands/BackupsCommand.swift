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

struct BackupsListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
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

struct BackupsRestoreCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a library backup by its safe backup handle."
    )

    @Argument(help: "Exact handle returned by `backups list`.")
    var handle: String

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "backups.restore" }

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> RestoreCommandResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .libraryBackup)
            return RestoreCommandResult(try books.restoreLibraryBackup(handle: handle))
        }
    }
}

struct BackupListResult: Codable, Equatable, Sendable {
    let items: [BackupResult]

}

struct BackupResult: Codable, Equatable, Sendable {
    let handle: String
    let createdAt: Date
    let sizeBytes: Int64

    init(_ backup: LibraryBackup) {
        handle = backup.handle
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
    let restoredFromHandle: String
    let safetyBackupHandle: String
    let warningCodes: [String]

    init(_ result: RestoreResult) {
        changed = result.restoreApplied
        status = result.verified ? .restoredVerified : .restoredUnverified
        verified = result.verified
        restoredFromHandle = result.restoredFromHandle
        safetyBackupHandle = result.safetyBackupHandle
        warningCodes = result.warnings.map(\.rawValue)
    }

}

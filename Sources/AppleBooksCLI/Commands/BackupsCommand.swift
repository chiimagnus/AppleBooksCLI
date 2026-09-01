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
        abstract: "List safe library backup handles and metadata."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> BackupListResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return BackupListResult(items: try books.listLibraryBackups().map(BackupResult.init))
        }
    }
}

struct BackupsRestoreCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a library backup by its safe backup handle."
    )

    @Argument(help: "Exact handle returned by `backups list`.")
    var handle: String

    @OptionGroup var global: GlobalOptions

    mutating func run() throws { try run(output: .standard) }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json { try output.writeJSON(result) } else { output.stdout(result.humanDescription) }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> RestoreCommandResult {
        try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return RestoreCommandResult(try books.restoreLibraryBackup(handle: handle))
        }
    }
}

struct BackupListResult: Codable, Equatable, Sendable {
    let items: [BackupResult]

    var humanDescription: String {
        items.isEmpty ? "No backups." : items.map(\.humanSummary).joined(separator: "\n")
    }
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

    var humanSummary: String {
        "\(handle)\t\(createdAt.formatted(.iso8601))\t\(sizeBytes)"
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

    var humanDescription: String {
        var lines = [
            "changed: \(changed)",
            "status: \(status.rawValue)",
            "verified: \(verified)",
            "restored from: \(restoredFromHandle)",
            "safety backup: \(safetyBackupHandle)",
        ]
        if warningCodes.isEmpty == false {
            lines.append("warnings: \(warningCodes.joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
    }
}

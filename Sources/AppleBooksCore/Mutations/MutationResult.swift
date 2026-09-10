import Foundation

public enum MutationWarning: String, Equatable, Sendable {
    case writableCloseFailed = "writable_close_failed"
    case readBackFailed = "read_back_failed"
    case cloudProjectionFailed = "cloud_projection_failed"
    case cloudSyncFailed = "cloud_sync_failed"
    case deeplinkOpenFailed = "deeplink_open_failed"
    case relaunchFailed = "relaunch_failed"
    case booksStateRestoreFailed = "books_state_restore_failed"
}

public enum MutationFailureCode: String, Equatable, Sendable {
    case preflightFailed = "preflight_failed"
    case quitFailed = "quit_failed"
    case backupFailed = "backup_failed"
    case databaseOpenFailed = "database_open_failed"
    case busyTimeoutFailed = "busy_timeout_failed"
    case beginFailed = "begin_failed"
    case revalidateFailed = "revalidate_failed"
    case mutationFailed = "mutation_failed"
    case invariantFailed = "invariant_failed"
    case commitFailed = "commit_failed"
}

public enum RestoreWarning: String, Equatable, Sendable {
    case verificationFailed = "verification_failed"
    case retentionFailed = "retention_failed"
    case relaunchFailed = "relaunch_failed"
}

public enum RestoreFailureCode: String, Equatable, Sendable {
    case sourceRejected = "source_rejected"
    case quitFailed = "quit_failed"
    case safetyBackupFailed = "safety_backup_failed"
    case restoreFailed = "restore_failed"
}

public struct RestoreResult: Equatable, Sendable {
    public let restoreApplied: Bool
    public let verified: Bool
    let restoredFromHandle: String
    let safetyBackupHandle: String
    public let warnings: [RestoreWarning]

    public var restoredFromBackupID: String? {
        BackupMetadata.backupID(fromFilename: restoredFromHandle)
    }

    public var safetyBackupID: String? {
        BackupMetadata.backupID(fromFilename: safetyBackupHandle)
    }

    init(
        restoredFromHandle: String,
        safetyBackupHandle: String,
        verified: Bool,
        warnings: [RestoreWarning]
    ) {
        restoreApplied = true
        self.verified = verified
        self.restoredFromHandle = restoredFromHandle
        self.safetyBackupHandle = safetyBackupHandle
        self.warnings = warnings
    }
}

public struct RestoreFailure: Error, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
    public let restoreApplied: Bool
    let safetyBackupHandle: String?
    public let code: RestoreFailureCode
    public let warnings: [RestoreWarning]
    let underlying: any Error

    init(
        safetyBackupHandle: String?,
        code: RestoreFailureCode,
        warnings: [RestoreWarning],
        underlying: any Error
    ) {
        restoreApplied = false
        self.safetyBackupHandle = safetyBackupHandle
        self.code = code
        self.warnings = warnings
        self.underlying = underlying
    }

    public var safetyBackupID: String? {
        safetyBackupHandle.flatMap(BackupMetadata.backupID(fromFilename:))
    }

    public var description: String {
        "RestoreFailure(restoreApplied=false, code=\(code.rawValue), hasSafetyBackup=\(safetyBackupHandle != nil), warnings=\(warnings.map(\.rawValue)))"
    }

    public var debugDescription: String { description }
    public var errorDescription: String? { description }
}

public struct MutationResult: Equatable, Sendable {
    public let committed: Bool
    let backupHandle: String
    public let localPK: Int64?
    public let stableID: String?
    public let changed: Bool
    public let warnings: [MutationWarning]
    public let appleBooksURL: String?

    public var backupID: String? {
        BackupMetadata.backupID(fromFilename: backupHandle)
    }

    init(
        backupHandle: String,
        localPK: Int64?,
        stableID: String?,
        changed: Bool,
        warnings: [MutationWarning],
        appleBooksURL: String? = nil
    ) {
        committed = true
        self.backupHandle = backupHandle
        self.localPK = localPK
        self.stableID = stableID
        self.changed = changed
        self.warnings = warnings
        self.appleBooksURL = appleBooksURL
    }
}

public struct MutationFailure: Error, CustomStringConvertible, CustomDebugStringConvertible, LocalizedError {
    public let committed: Bool
    let backupHandle: String?
    public let code: MutationFailureCode
    public let warnings: [MutationWarning]
    let underlying: any Error

    init(
        backupHandle: String?,
        code: MutationFailureCode,
        warnings: [MutationWarning],
        underlying: any Error
    ) {
        committed = false
        self.backupHandle = backupHandle
        self.code = code
        self.warnings = warnings
        self.underlying = underlying
    }

    public var backupID: String? {
        backupHandle.flatMap(BackupMetadata.backupID(fromFilename:))
    }

    public var description: String {
        "MutationFailure(committed=false, code=\(code.rawValue), hasBackup=\(backupHandle != nil), warnings=\(warnings.map(\.rawValue)))"
    }

    public var debugDescription: String { description }
    public var errorDescription: String? { description }
}

struct MutationDomainData: Equatable, Sendable {
    let localPK: Int64?
    let stableID: String?
    let changed: Bool
    let appleBooksURL: String?

    init(
        localPK: Int64? = nil,
        stableID: String? = nil,
        changed: Bool = true,
        appleBooksURL: String? = nil
    ) {
        self.localPK = localPK
        self.stableID = stableID
        self.changed = changed
        self.appleBooksURL = appleBooksURL
    }
}

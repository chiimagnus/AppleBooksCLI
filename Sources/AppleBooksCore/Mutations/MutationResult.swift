public enum MutationWarning: String, Equatable, Sendable {
    case writableCloseFailed = "writable_close_failed"
    case readBackFailed = "read_back_failed"
    case relaunchFailed = "relaunch_failed"
}

public enum MutationFailureCode: String, Equatable, Sendable {
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

public struct MutationResult: Equatable, Sendable {
    public let committed: Bool
    public let backupHandle: String
    public let localPK: Int64?
    public let stableID: String?
    public let changed: Bool
    public let warnings: [MutationWarning]

    init(
        backupHandle: String,
        localPK: Int64?,
        stableID: String?,
        changed: Bool,
        warnings: [MutationWarning]
    ) {
        committed = true
        self.backupHandle = backupHandle
        self.localPK = localPK
        self.stableID = stableID
        self.changed = changed
        self.warnings = warnings
    }
}

public struct MutationFailure: Error {
    public let committed: Bool
    public let backupHandle: String?
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
}

struct MutationDomainData: Equatable, Sendable {
    let localPK: Int64?
    let stableID: String?
    let changed: Bool

    init(localPK: Int64? = nil, stableID: String? = nil, changed: Bool = true) {
        self.localPK = localPK
        self.stableID = stableID
        self.changed = changed
    }
}

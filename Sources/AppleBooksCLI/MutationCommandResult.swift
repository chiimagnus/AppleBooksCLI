import AppleBooksCore

struct MutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let backupID: String
    let localPK: Int64?
    let stableID: String?
    let warningCodes: [String]
    let appleBooksURL: String?

    init(_ result: MutationResult) throws {
        guard let backupID = result.backupID else { throw CLIError.internalFailure }
        committed = result.committed
        changed = result.changed
        self.backupID = backupID
        localPK = result.localPK
        stableID = result.stableID
        warningCodes = result.warnings.map(\.rawValue)
        appleBooksURL = result.appleBooksURL
    }

}

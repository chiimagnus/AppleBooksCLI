import AppleBooksCore

struct MutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let backupHandle: String
    let localPK: Int64?
    let stableID: String?
    let warningCodes: [String]
    let appleBooksURL: String?

    init(_ result: MutationResult) {
        committed = result.committed
        changed = result.changed
        backupHandle = result.backupHandle
        localPK = result.localPK
        stableID = result.stableID
        warningCodes = result.warnings.map(\.rawValue)
        appleBooksURL = result.appleBooksURL
    }

    var humanDescription: String {
        var lines = [changed ? "Mutation committed." : "No change."]
        if warningCodes.isEmpty == false {
            lines.append("warnings: \(warningCodes.joined(separator: ","))")
        }
        if let appleBooksURL {
            lines.append(appleBooksURL)
        }
        return lines.joined(separator: "\n")
    }
}

import AppleBooksCore

struct MutationCommandResult: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case committed
        case changed
        case backupID
        case localPK
        case stableID
        case acknowledgementRequested
        case acknowledged
        case warningCodes
        case appleBooksURL
    }

    let committed: Bool
    let changed: Bool
    let backupID: String?
    let localPK: Int64?
    let stableID: String?
    let acknowledgementRequested: Bool
    let acknowledged: Bool?
    let warningCodes: [String]
    let appleBooksURL: String?

    init(_ result: MutationResult) {
        committed = result.committed
        changed = result.changed
        backupID = result.backupID
        localPK = result.localPK
        stableID = result.stableID
        acknowledgementRequested = result.acknowledgementRequested
        acknowledged = result.acknowledged
        warningCodes = result.warnings.map(\.rawValue)
        appleBooksURL = result.appleBooksURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        committed = try container.decode(Bool.self, forKey: .committed)
        changed = try container.decode(Bool.self, forKey: .changed)
        backupID = try container.decodeIfPresent(String.self, forKey: .backupID)
        localPK = try container.decodeIfPresent(Int64.self, forKey: .localPK)
        stableID = try container.decodeIfPresent(String.self, forKey: .stableID)
        acknowledgementRequested = try container.decode(Bool.self, forKey: .acknowledgementRequested)
        acknowledged = try container.decodeIfPresent(Bool.self, forKey: .acknowledged)
        warningCodes = try container.decode([String].self, forKey: .warningCodes)
        appleBooksURL = try container.decodeIfPresent(String.self, forKey: .appleBooksURL)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(committed, forKey: .committed)
        try container.encode(changed, forKey: .changed)
        try container.encodeIfPresent(backupID, forKey: .backupID)
        try container.encodeIfPresent(localPK, forKey: .localPK)
        try container.encodeIfPresent(stableID, forKey: .stableID)
        try container.encode(acknowledgementRequested, forKey: .acknowledgementRequested)
        try container.encode(acknowledged, forKey: .acknowledged)
        try container.encode(warningCodes, forKey: .warningCodes)
        try container.encodeIfPresent(appleBooksURL, forKey: .appleBooksURL)
    }
}

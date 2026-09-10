import Foundation

public enum LibraryBackupIdentityError: Error, Equatable, Sendable {
    case invalidBackupID
}

public struct LibraryBackup: Equatable, Sendable {
    public let handle: String
    public let backupID: String
    public let createdAt: Date
    public let sizeBytes: Int64

    public static func isValidBackupID(_ value: String) -> Bool {
        BackupMetadata.parseIdentity(backupID: value) != nil
    }

    init(handle: String, backupID: String, createdAt: Date, sizeBytes: Int64) {
        self.handle = handle
        self.backupID = backupID
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
    }
}

struct BackupMetadata: Equatable {
    static let timestampFormat = "yyyyMMdd-HHmmss-SSSSSS"
    static let backupIDPrefix = "abk1_"
    static let backupIDLength = 64
    private static let timestampLength = 22

    fileprivate struct PublicIdentity {
        let timestamp: Date
        let uuid: UUID
    }

    let sourceStem: String
    let timestamp: Date
    let uuid: UUID

    var filename: String {
        "\(sourceStem)__\(Self.format(timestamp))__\(uuid.uuidString.lowercased()).sqlite"
    }

    var backupID: String {
        "\(Self.backupIDPrefix)\(Self.format(timestamp))_\(uuid.uuidString.lowercased())"
    }

    static func fresh(sourceStem: String, now: Date = Date(), uuid: UUID = UUID()) -> BackupMetadata {
        BackupMetadata(sourceStem: sourceStem, timestamp: now, uuid: uuid)
    }

    static func parse(filename: String, sourceStem: String) -> BackupMetadata? {
        let prefix = sourceStem + "__"
        guard filename.hasPrefix(prefix), filename.hasSuffix(".sqlite") else { return nil }
        let body = String(filename.dropFirst(prefix.count).dropLast(".sqlite".count))
        let parts = body.components(separatedBy: "__")
        guard parts.count == 2,
              let timestamp = parseTimestamp(parts[0]),
              let uuid = UUID(uuidString: parts[1]) else {
            return nil
        }
        return BackupMetadata(sourceStem: sourceStem, timestamp: timestamp, uuid: uuid)
    }

    static func parse(backupID: String, sourceStem: String) -> BackupMetadata? {
        guard let identity = parseIdentity(backupID: backupID) else { return nil }
        return BackupMetadata(sourceStem: sourceStem, timestamp: identity.timestamp, uuid: identity.uuid)
    }

    static func backupID(fromLegacyFilename filename: String) -> String? {
        guard filename.hasSuffix(".sqlite") else { return nil }
        let body = filename.dropLast(".sqlite".count)
        guard let uuidSeparator = body.range(of: "__", options: .backwards) else { return nil }
        let beforeUUID = body[..<uuidSeparator.lowerBound]
        let uuidText = String(body[uuidSeparator.upperBound...])
        guard let timestampSeparator = beforeUUID.range(of: "__", options: .backwards) else { return nil }
        let sourceStem = String(beforeUUID[..<timestampSeparator.lowerBound])
        let timestampText = String(beforeUUID[timestampSeparator.upperBound...])
        guard sourceStem.isEmpty == false,
              let timestamp = parseTimestamp(timestampText),
              let uuid = UUID(uuidString: uuidText) else {
            return nil
        }
        return BackupMetadata(sourceStem: sourceStem, timestamp: timestamp, uuid: uuid).backupID
    }

    fileprivate static func parseIdentity(backupID: String) -> PublicIdentity? {
        guard backupID.utf8.count == backupIDLength,
              backupID.utf8.allSatisfy({ $0 < 0x80 }),
              backupID.hasPrefix(backupIDPrefix) else {
            return nil
        }
        let body = backupID.dropFirst(backupIDPrefix.count)
        let parts = body.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let timestampText = String(parts[0])
        let uuidText = String(parts[1])
        guard timestampText.utf8.count == timestampLength,
              uuidText.utf8.count == 36,
              let timestamp = parseTimestamp(timestampText),
              format(timestamp) == timestampText,
              let uuid = UUID(uuidString: uuidText),
              uuid.uuidString.lowercased() == uuidText else {
            return nil
        }
        return PublicIdentity(timestamp: timestamp, uuid: uuid)
    }

    private static func format(_ date: Date) -> String {
        formatter().string(from: date)
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        formatter().date(from: value)
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = timestampFormat
        formatter.isLenient = false
        return formatter
    }
}

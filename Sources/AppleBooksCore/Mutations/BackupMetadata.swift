import Foundation

public struct LibraryBackup: Equatable, Sendable {
    public let handle: String
    public let createdAt: Date
    public let sizeBytes: Int64

    init(handle: String, createdAt: Date, sizeBytes: Int64) {
        self.handle = handle
        self.createdAt = createdAt
        self.sizeBytes = sizeBytes
    }
}

struct BackupMetadata: Equatable {
    static let timestampFormat = "yyyyMMdd-HHmmss-SSSSSS"

    let sourceStem: String
    let timestamp: Date
    let uuid: UUID

    var filename: String {
        "\(sourceStem)__\(Self.format(timestamp))__\(uuid.uuidString.lowercased()).sqlite"
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
        return formatter
    }
}

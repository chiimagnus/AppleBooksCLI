import Foundation

public enum CoreDataTime {
    public static let unixEpochOffset: TimeInterval = 978_307_200

    public static func date(from seconds: Double?) -> Date? {
        seconds.map { Date(timeIntervalSince1970: $0 + unixEpochOffset) }
    }

    public static func seconds(from date: Date?) -> Double? {
        date.map { $0.timeIntervalSince1970 - unixEpochOffset }
    }
}

import Foundation

public enum CoreDataTime {
    public static let unixEpochOffset: TimeInterval = 978_307_200

    static let minimumUnixSeconds: TimeInterval = -62_135_596_800
    static let maximumUnixSecondsExclusive: TimeInterval = 253_402_300_800
    static let minimumSeconds: TimeInterval = minimumUnixSeconds - unixEpochOffset
    static let maximumSecondsExclusive: TimeInterval = maximumUnixSecondsExclusive - unixEpochOffset

    public static func date(from seconds: Double?) -> Date? {
        guard let seconds,
              seconds.isFinite,
              seconds >= minimumSeconds,
              seconds < maximumSecondsExclusive else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds + unixEpochOffset)
    }

    public static func seconds(from date: Date?) -> Double? {
        guard let date else { return nil }
        let unixSeconds = date.timeIntervalSince1970
        guard unixSeconds.isFinite,
              unixSeconds >= minimumUnixSeconds,
              unixSeconds < maximumUnixSecondsExclusive else {
            return nil
        }
        return unixSeconds - unixEpochOffset
    }
}

package enum SemanticSQLiteReal {
    package static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    package static func readingProgressPercent(_ value: Double?) -> Double? {
        guard let value = finite(value) else { return nil }
        if value <= 0 { return 0 }
        if value >= 1 { return 100 }
        return value * 100
    }

    static func finiteSQL(_ expression: String) -> String {
        "CASE WHEN typeof(\(expression)) IN ('integer','real') AND \(expression) >= -1.7976931348623157e308 AND \(expression) <= 1.7976931348623157e308 THEN \(expression) ELSE NULL END"
    }

    static func dateSQL(_ expression: String) -> String {
        "CASE WHEN typeof(\(expression)) IN ('integer','real') AND \(expression) >= \(CoreDataTime.minimumSeconds) AND \(expression) < \(CoreDataTime.maximumSecondsExclusive) THEN \(expression) ELSE NULL END"
    }
}

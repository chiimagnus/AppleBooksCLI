import Foundation

struct BoundedSQLiteText: Equatable, Sendable {
    let value: String?
    let originalUTF8ByteCount: Int?
    let wasByteTruncated: Bool
}

enum ExactSQLiteText: Equatable, Sendable {
    case null
    case value(String)
    case oversized(originalUTF8ByteCount: Int)
}

enum SQLiteSemanticTextBudget {
    static let stableIdentity = PublicStableIdentityPolicy.maximumUTF8Bytes
    static let shortMetadata = 2 * 1_024
    static let preview = 4 * 1_024
    static let metadata = 8 * 1_024
    static let detail = 32 * 1_024
    static let resourcePath = 4 * 1_024
}

enum SQLiteTextProjection {
    static func bounded(
        _ expression: String,
        alias: String,
        maximumUTF8Bytes: Int
    ) -> [String] {
        precondition(maximumUTF8Bytes > 0)
        let type = "typeof(\(expression))"
        let blob = "CAST(\(expression) AS BLOB)"
        return [
            "\(type) AS \(storageAlias(alias))",
            "CASE WHEN \(type) = 'text' THEN length(\(blob)) END AS \(lengthAlias(alias))",
            "CASE WHEN \(type) = 'text' THEN COALESCE(substr(\(blob), 1, \(maximumUTF8Bytes + 4)), X'') END AS \(payloadAlias(alias))",
        ]
    }

    static func exact(
        _ expression: String,
        alias: String,
        maximumUTF8Bytes: Int
    ) -> [String] {
        precondition(maximumUTF8Bytes > 0)
        let type = "typeof(\(expression))"
        let blob = "CAST(\(expression) AS BLOB)"
        let length = "length(\(blob))"
        return [
            "\(type) AS \(storageAlias(alias))",
            "CASE WHEN \(type) = 'text' THEN \(length) END AS \(lengthAlias(alias))",
            "CASE WHEN \(type) = 'text' AND \(length) <= \(maximumUTF8Bytes) THEN \(blob) END AS \(payloadAlias(alias))",
        ]
    }

    static func decodeBounded(
        _ row: SQLiteRow,
        alias: String,
        column: String,
        maximumUTF8Bytes: Int
    ) throws -> BoundedSQLiteText {
        switch try storageClass(row, alias: alias, column: column) {
        case .null:
            return BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
        case .text:
            break
        }

        guard let rawLength = try row.int64(lengthAlias(alias)),
              rawLength >= 0,
              rawLength <= Int64(Int.max),
              let payload = try row.blob(payloadAlias(alias)) else {
            throw QueryDecodingError.nullRequiredColumn(column)
        }
        let originalLength = Int(rawLength)
        let decoded = try decodePrefix(
            payload,
            originalUTF8ByteCount: originalLength,
            column: column
        )
        let bounded = boundToWholeCharacters(decoded, maximumUTF8Bytes: maximumUTF8Bytes)
        return BoundedSQLiteText(
            value: bounded,
            originalUTF8ByteCount: originalLength,
            wasByteTruncated: originalLength > bounded.utf8.count
        )
    }

    static func decodeExact(
        _ row: SQLiteRow,
        alias: String,
        column: String,
        maximumUTF8Bytes: Int
    ) throws -> ExactSQLiteText {
        switch try storageClass(row, alias: alias, column: column) {
        case .null:
            return .null
        case .text:
            break
        }

        guard let rawLength = try row.int64(lengthAlias(alias)),
              rawLength >= 0,
              rawLength <= Int64(Int.max) else {
            throw QueryDecodingError.nullRequiredColumn(column)
        }
        let originalLength = Int(rawLength)
        guard originalLength <= maximumUTF8Bytes else {
            return .oversized(originalUTF8ByteCount: originalLength)
        }
        guard let payload = try row.blob(payloadAlias(alias)),
              let value = String(data: payload, encoding: .utf8) else {
            throw SQLiteRowError.invalidUTF8(column: column)
        }
        return .value(value)
    }

    private enum StorageClass {
        case null
        case text
    }

    private static func storageClass(
        _ row: SQLiteRow,
        alias: String,
        column: String
    ) throws -> StorageClass {
        guard let storage = try row.text(storageAlias(alias)) else {
            throw QueryDecodingError.nullRequiredColumn(column)
        }
        switch storage {
        case "null":
            return .null
        case "text":
            return .text
        default:
            throw SQLiteRowError.typeMismatch(
                column: column,
                expected: "TEXT",
                actual: storage.uppercased()
            )
        }
    }

    private static func decodePrefix(
        _ payload: Data,
        originalUTF8ByteCount: Int,
        column: String
    ) throws -> String {
        if let value = String(data: payload, encoding: .utf8) {
            return value
        }
        guard originalUTF8ByteCount > payload.count else {
            throw SQLiteRowError.invalidUTF8(column: column)
        }
        let bytes = [UInt8](payload)
        for removedCount in 1...min(3, bytes.count) {
            let split = bytes.count - removedCount
            let suffix = Array(bytes[split...])
            guard isIncompleteUTF8ScalarPrefix(suffix),
                  let value = String(bytes: bytes[..<split], encoding: .utf8) else {
                continue
            }
            return value
        }
        throw SQLiteRowError.invalidUTF8(column: column)
    }

    private static func isIncompleteUTF8ScalarPrefix(_ bytes: [UInt8]) -> Bool {
        guard let lead = bytes.first else { return false }
        let scalarLength: Int
        switch lead {
        case 0xC2...0xDF:
            scalarLength = 2
        case 0xE0...0xEF:
            scalarLength = 3
        case 0xF0...0xF4:
            scalarLength = 4
        default:
            return false
        }
        guard bytes.count < scalarLength else { return false }
        if bytes.count >= 2 {
            let second = bytes[1]
            let validSecond: Bool
            switch lead {
            case 0xE0:
                validSecond = (0xA0...0xBF).contains(second)
            case 0xED:
                validSecond = (0x80...0x9F).contains(second)
            case 0xF0:
                validSecond = (0x90...0xBF).contains(second)
            case 0xF4:
                validSecond = (0x80...0x8F).contains(second)
            default:
                validSecond = (0x80...0xBF).contains(second)
            }
            guard validSecond else { return false }
        }
        if bytes.count >= 3 {
            guard bytes[2...].allSatisfy({ (0x80...0xBF).contains($0) }) else { return false }
        }
        return true
    }

    private static func boundToWholeCharacters(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = ""
        var byteCount = 0
        for character in value {
            let characterBytes = character.utf8.count
            guard byteCount <= maximumUTF8Bytes - characterBytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result
    }

    private static func storageAlias(_ alias: String) -> String { "__ab_\(alias)_storage" }
    private static func lengthAlias(_ alias: String) -> String { "__ab_\(alias)_bytes" }
    private static func payloadAlias(_ alias: String) -> String { "__ab_\(alias)_payload" }
}

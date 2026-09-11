import AppleBooksCloudBridge
import Foundation
import SQLite3

enum CloudProjectionResourcePolicy {
    static let stableIdentityBytes = Int(ABCloudProjectionMaximumIdentityBytes)
    static let annotationNoteBytes = Int(ABCloudProjectionMaximumAnnotationNoteBytes)
    static let collectionTitleBytes = Int(ABCloudProjectionMaximumCollectionTitleBytes)
    static let collectionDetailsBytes = Int(ABCloudProjectionMaximumCollectionDetailsBytes)
    static let fixedMetadataBytes = Int(ABCloudProjectionMaximumFixedMetadataBytes)
    static let bookAnnotationsBytes = Int(ABCloudProjectionMaximumBookAnnotationsBytes)

    static func exactTextProjection(_ expression: String, maximumUTF8Bytes: Int = stableIdentityBytes) -> String {
        precondition(maximumUTF8Bytes > 0)
        let type = "typeof(\(expression))"
        let blob = "CAST(\(expression) AS BLOB)"
        return "CASE \(type) WHEN 'null' THEN 0 WHEN 'text' THEN 1 ELSE 2 END, CASE WHEN \(type)='text' THEN length(\(blob)) END, CASE WHEN \(type)='text' AND length(\(blob)) <= \(maximumUTF8Bytes) THEN \(blob) END"
    }

    static func exactText(
        _ statement: OpaquePointer,
        storageIndex: Int32,
        lengthIndex: Int32,
        payloadIndex: Int32,
        maximumUTF8Bytes: Int = stableIdentityBytes
    ) throws -> ExactSQLiteText {
        guard sqlite3_column_type(statement, storageIndex) == SQLITE_INTEGER else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        switch sqlite3_column_int64(statement, storageIndex) {
        case 0:
            return .null
        case 1:
            break
        default:
            throw SQLiteTextCodecError.invalidUTF8
        }
        guard sqlite3_column_type(statement, lengthIndex) == SQLITE_INTEGER else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        let rawLength = sqlite3_column_int64(statement, lengthIndex)
        guard rawLength >= 0, rawLength <= Int64(Int.max) else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        let byteCount = Int(rawLength)
        guard byteCount <= maximumUTF8Bytes else {
            return .oversized(originalUTF8ByteCount: byteCount)
        }
        guard sqlite3_column_type(statement, payloadIndex) == SQLITE_BLOB else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        let payloadCount = Int(sqlite3_column_bytes(statement, payloadIndex))
        guard payloadCount == byteCount else { throw SQLiteTextCodecError.invalidUTF8 }
        if payloadCount == 0 { return .value("") }
        guard let pointer = sqlite3_column_blob(statement, payloadIndex) else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: payloadCount)
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw SQLiteTextCodecError.invalidUTF8
        }
        return .value(value)
    }
}

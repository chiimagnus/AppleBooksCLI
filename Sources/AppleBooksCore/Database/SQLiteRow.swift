import Foundation
import SQLite3

public enum SQLiteRowError: Error, Equatable, Sendable {
    case invalidStatement
    case missingColumn(String)
    case typeMismatch(column: String, expected: String, actual: String)
}

struct SQLiteRow {
    private let statement: OpaquePointer
    private let columns: [String: Int32]

    init(statement: SQLiteStatement) throws {
        guard let handle = statement.handle else {
            throw SQLiteRowError.invalidStatement
        }
        self.statement = handle
        var columns: [String: Int32] = [:]
        for index in 0..<sqlite3_column_count(handle) {
            if let name = sqlite3_column_name(handle, index) {
                columns[String(cString: name)] = index
            }
        }
        self.columns = columns
    }

    func int64(_ column: String) throws -> Int64? {
        let index = try index(of: column)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_INTEGER:
            return sqlite3_column_int64(statement, index)
        default:
            throw mismatch(column, expected: "INTEGER", index: index)
        }
    }

    func double(_ column: String) throws -> Double? {
        let index = try index(of: column)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_FLOAT, SQLITE_INTEGER:
            return sqlite3_column_double(statement, index)
        default:
            throw mismatch(column, expected: "numeric", index: index)
        }
    }

    func text(_ column: String) throws -> String? {
        let index = try index(of: column)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_TEXT:
            guard let value = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: value)
        default:
            throw mismatch(column, expected: "TEXT", index: index)
        }
    }

    func blob(_ column: String) throws -> Data? {
        let index = try index(of: column)
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0 else { return Data() }
            guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: bytes, count: count)
        default:
            throw mismatch(column, expected: "BLOB", index: index)
        }
    }

    private func index(of column: String) throws -> Int32 {
        guard let index = columns[column] else {
            throw SQLiteRowError.missingColumn(column)
        }
        return index
    }

    private func mismatch(_ column: String, expected: String, index: Int32) -> SQLiteRowError {
        SQLiteRowError.typeMismatch(
            column: column,
            expected: expected,
            actual: storageClassName(sqlite3_column_type(statement, index))
        )
    }

    private func storageClassName(_ type: Int32) -> String {
        switch type {
        case SQLITE_INTEGER: "INTEGER"
        case SQLITE_FLOAT: "FLOAT"
        case SQLITE_TEXT: "TEXT"
        case SQLITE_BLOB: "BLOB"
        case SQLITE_NULL: "NULL"
        default: "UNKNOWN"
        }
    }
}

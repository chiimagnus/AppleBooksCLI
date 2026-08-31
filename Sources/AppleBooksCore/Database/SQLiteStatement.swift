import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SQLiteStatement {
    private let connection: SQLiteConnection
    var handle: OpaquePointer?

    init(connection: SQLiteConnection, sql: String) throws {
        self.connection = connection
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw SQLiteError.current(operation: .prepare, code: result, handle: connection.handle)
        }
        handle = statement
    }

    public func bindNull(at index: Int32) throws {
        try checkBind(sqlite3_bind_null(handle, index))
    }

    public func bind(_ value: Int64, at index: Int32) throws {
        try checkBind(sqlite3_bind_int64(handle, index, value))
    }

    public func bind(_ value: Double, at index: Int32) throws {
        try checkBind(sqlite3_bind_double(handle, index, value))
    }

    public func bind(_ value: String, at index: Int32) throws {
        let result = value.withCString { pointer in
            sqlite3_bind_text(handle, index, pointer, -1, sqliteTransient)
        }
        try checkBind(result)
    }

    public func bind(_ value: Data, at index: Int32) throws {
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_zeroblob(handle, index, 0)
        } else {
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(handle, index, bytes.baseAddress, Int32(bytes.count), sqliteTransient)
            }
        }
        try checkBind(result)
    }

    @discardableResult
    public func step() throws -> Bool {
        let result = sqlite3_step(handle)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw SQLiteError.current(operation: .step, code: result, handle: connection.handle)
        }
    }

    private func checkBind(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .bind, code: result, handle: connection.handle)
        }
    }

    deinit {
        if let handle {
            sqlite3_finalize(handle)
        }
    }
}

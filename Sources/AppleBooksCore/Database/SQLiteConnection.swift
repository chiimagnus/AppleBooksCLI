import SQLite3

public final class SQLiteConnection {
    var handle: OpaquePointer?

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    public static func readOnly(path: String) throws -> SQLiteConnection {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let handle else {
            let error = SQLiteError.current(operation: .open, code: result, handle: handle)
            if let handle {
                sqlite3_close_v2(handle)
            }
            throw error
        }
        return SQLiteConnection(handle: handle)
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        guard handle != nil else {
            throw SQLiteError(operation: .prepare, code: SQLITE_MISUSE, message: "connection is closed")
        }
        return try SQLiteStatement(connection: self, sql: sql)
    }

    public func close() throws {
        guard let handle else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .close, code: result, handle: handle)
        }
        self.handle = nil
    }

    deinit {
        if let handle {
            sqlite3_close_v2(handle)
        }
    }
}

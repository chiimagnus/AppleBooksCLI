import SQLite3

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public enum Operation: String, Equatable, Sendable {
        case open
        case prepare
        case bind
        case step
        case close
    }

    public let operation: Operation
    public let code: Int32
    public let message: String

    public var description: String {
        "SQLite \(operation.rawValue) failed (\(code)): \(message)"
    }

    static func current(operation: Operation, code: Int32, handle: OpaquePointer?) -> SQLiteError {
        let message = handle.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown SQLite error"
        return SQLiteError(operation: operation, code: code, message: message)
    }
}

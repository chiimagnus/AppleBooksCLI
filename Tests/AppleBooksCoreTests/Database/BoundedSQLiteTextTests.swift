import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("BoundedSQLiteTextTests")
struct BoundedSQLiteTextTests {
    @Test
    func boundedProjectionRepairsOnlyIncompleteTrailingScalarAndKeepsWholeCharacters() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.insert(id: 1, value: "abcdé👩x")
        try fixture.insert(id: 2, value: "e\u{301}x")
        try fixture.insert(id: 3, value: "a👩‍💻b")
        try fixture.insert(id: 4, value: "a🇺🇸b")
        try fixture.insert(id: 5, value: "ab\0cd")

        let connection = try SQLiteConnection.readOnly(path: fixture.database.path)
        let scalarCut = try boundedValue(connection: connection, id: 1, maximumUTF8Bytes: 4)
        #expect(scalarCut.value == "abcd")
        #expect(scalarCut.originalUTF8ByteCount == "abcdé👩x".utf8.count)
        #expect(scalarCut.wasByteTruncated)

        let combining = try boundedValue(connection: connection, id: 2, maximumUTF8Bytes: 2)
        #expect(combining.value == "")
        #expect(combining.wasByteTruncated)

        let zwj = try boundedValue(connection: connection, id: 3, maximumUTF8Bytes: 1)
        #expect(zwj.value == "a")
        #expect(zwj.wasByteTruncated)

        let regionalIndicator = try boundedValue(connection: connection, id: 4, maximumUTF8Bytes: 1)
        #expect(regionalIndicator.value == "a")
        #expect(regionalIndicator.wasByteTruncated)

        let nul = try boundedValue(connection: connection, id: 5, maximumUTF8Bytes: 16)
        #expect(nul.value == "ab\0cd")
        #expect(nul.wasByteTruncated == false)
    }

    @Test
    func boundedProjectionRejectsMalformedUTF8InsidePrefix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.insertMalformedUTF8(id: 99)
        let connection = try SQLiteConnection.readOnly(path: fixture.database.path)

        #expect(throws: SQLiteRowError.invalidUTF8(column: "value")) {
            _ = try boundedValue(connection: connection, id: 99, maximumUTF8Bytes: 16)
        }
    }

    @Test
    func exactProjectionUsesSQLLengthEvidenceAndNeverReturnsOversizePayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let exact = String(repeating: "i", count: 2_048)
        let oversized = String(repeating: "j", count: 2_049)
        try fixture.insert(id: 1, value: exact)
        try fixture.insert(id: 2, value: oversized)
        let connection = try SQLiteConnection.readOnly(path: fixture.database.path)

        #expect(try exactValue(connection: connection, id: 1, maximumUTF8Bytes: 2_048) == .value(exact))
        #expect(try exactValue(connection: connection, id: 2, maximumUTF8Bytes: 2_048) == .oversized(originalUTF8ByteCount: 2_049))
    }

    private func boundedValue(
        connection: SQLiteConnection,
        id: Int64,
        maximumUTF8Bytes: Int
    ) throws -> BoundedSQLiteText {
        let projection = SQLiteTextProjection.bounded(
            "value",
            alias: "value",
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        let statement = try connection.prepare("SELECT \(projection.joined(separator: ", ")) FROM sample WHERE id = ?")
        try statement.bind(id, at: 1)
        guard try statement.step() else { throw FixtureError.missingRow }
        return try SQLiteTextProjection.decodeBounded(
            SQLiteRow(statement: statement),
            alias: "value",
            column: "value",
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    private func exactValue(
        connection: SQLiteConnection,
        id: Int64,
        maximumUTF8Bytes: Int
    ) throws -> ExactSQLiteText {
        let projection = SQLiteTextProjection.exact(
            "value",
            alias: "value",
            maximumUTF8Bytes: maximumUTF8Bytes
        )
        let statement = try connection.prepare("SELECT \(projection.joined(separator: ", ")) FROM sample WHERE id = ?")
        try statement.bind(id, at: 1)
        guard try statement.step() else { throw FixtureError.missingRow }
        return try SQLiteTextProjection.decodeExact(
            SQLiteRow(statement: statement),
            alias: "value",
            column: "value",
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    private final class Fixture {
        let root: URL
        let database: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            database = root.appendingPathComponent("bounded.sqlite")
            var handle: OpaquePointer?
            let open = sqlite3_open(database.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw SQLiteError.current(operation: .open, code: open, handle: handle)
            }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, "CREATE TABLE sample(id INTEGER PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
        }

        func insert(id: Int64, value: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(database.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw SQLiteError.current(operation: .open, code: open, handle: handle)
            }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(handle, "INSERT INTO sample VALUES(?, ?)", -1, &statement, nil)
            guard prepare == SQLITE_OK, let statement else {
                throw SQLiteError.current(operation: .prepare, code: prepare, handle: handle)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bytes = Array(value.utf8)
            guard sqlite3_bind_int64(statement, 1, id) == SQLITE_OK,
                  bytes.withUnsafeBytes({ raw in
                      sqlite3_bind_text(statement, 2, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(bytes.count), transient)
                  }) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
        }

        func insertMalformedUTF8(id: Int64) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(database.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw SQLiteError.current(operation: .open, code: open, handle: handle)
            }
            defer { sqlite3_close_v2(handle) }
            let sql = "INSERT INTO sample VALUES(\(id), CAST(X'61FF62' AS TEXT))"
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureError: Error {
        case missingRow
    }
}

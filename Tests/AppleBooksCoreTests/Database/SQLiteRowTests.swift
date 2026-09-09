import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("SQLiteRowTests")
struct SQLiteRowTests {
    @Test
    func extractsExactStorageClassesAndNulls() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)
        let statement = try connection.prepare("SELECT i, r, t, b, n FROM values_table")
        #expect(try statement.step())
        let row = try SQLiteRow(statement: statement)
        #expect(try row.int64("i") == 42)
        #expect(try row.double("r") == 3.5)
        #expect(try row.text("t") == "text")
        #expect(try row.blob("b") == Data([0, 1, 2]))
        #expect(try row.text("n") == nil)
    }

    @Test
    func textDecodingPreservesEmbeddedNULAndRejectsInvalidUTF8() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)

        let exact = try connection.prepare("SELECT value FROM text_edges WHERE rowid=1")
        #expect(try exact.step())
        #expect(try SQLiteRow(statement: exact).text("value") == "a\0b")

        let empty = try connection.prepare("SELECT value FROM text_edges WHERE rowid=2")
        #expect(try empty.step())
        #expect(try SQLiteRow(statement: empty).text("value") == "")

        let invalid = try connection.prepare("SELECT value FROM text_edges WHERE rowid=3")
        #expect(try invalid.step())
        #expect(throws: SQLiteRowError.invalidUTF8(column: "value")) {
            _ = try SQLiteRow(statement: invalid).text("value")
        }
    }

    @Test
    func missingColumnsAndTypeMismatchesFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)
        let statement = try connection.prepare("SELECT i, t FROM values_table")
        #expect(try statement.step())
        let row = try SQLiteRow(statement: statement)

        #expect(throws: SQLiteRowError.missingColumn("missing")) {
            _ = try row.text("missing")
        }
        #expect(throws: SQLiteRowError.typeMismatch(column: "t", expected: "INTEGER", actual: "TEXT")) {
            _ = try row.int64("t")
        }
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("row.sqlite")
        var database: OpaquePointer?
        let open = sqlite3_open(url.path, &database)
        guard open == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: open, handle: database)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE values_table(i INTEGER, r REAL, t TEXT, b BLOB, n TEXT);
        INSERT INTO values_table VALUES (42, 3.5, 'text', X'000102', NULL);
        CREATE TABLE text_edges(value TEXT);
        INSERT INTO text_edges(value) VALUES
            (CAST(X'610062' AS TEXT)),
            (''),
            (CAST(X'80' AS TEXT));
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
        return url
    }
}

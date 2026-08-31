import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("SQLiteConnectionTests")
struct SQLiteConnectionTests {
    @Test
    func opensStrictlyReadOnlyAndRejectsMutations() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }

        let connection = try SQLiteConnection.readOnly(path: fixture.path)
        guard let handle = connection.handle else {
            Issue.record("read-only connection did not expose an open handle")
            return
        }
        #expect(sqlite3_db_readonly(handle, "main") == 1)

        for sql in [
            "INSERT INTO items(value) VALUES ('blocked')",
            "UPDATE items SET value = 'blocked'",
            "DELETE FROM items",
            "CREATE TABLE blocked(id INTEGER)",
            "PRAGMA journal_mode=WAL",
        ] {
            do {
                let statement = try connection.prepare(sql)
                _ = try statement.step()
                Issue.record("read-only SQLite unexpectedly accepted a mutation")
            } catch {
                #expect(error is SQLiteError)
            }
        }

        let journalMode = try connection.prepare("PRAGMA journal_mode")
        #expect(try journalMode.step())
    }

    @Test
    func statementsBindValuesAndLiteralLikePatterns() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)

        for (needle, expected) in [
            ("O'Reilly", "O'Reilly"),
            ("100%", "100% literal"),
            ("under_", "under_score"),
            ("back\\slash", "back\\slash"),
        ] {
            let statement = try connection.prepare("SELECT value FROM items WHERE value LIKE ? ESCAPE '\\'")
            try statement.bind(literalContainsPattern(needle), at: 1)
            #expect(try statement.step())
            #expect(columnText(statement, at: 0) == expected)
            #expect(try statement.step() == false)
        }

        let typed = try connection.prepare("SELECT typeof(?), ?, ?, ?, length(?)")
        try typed.bindNull(at: 1)
        try typed.bind(Int64(42), at: 2)
        try typed.bind(3.5, at: 3)
        try typed.bind("bound text", at: 4)
        try typed.bind(Data([0x00, 0x01, 0x02]), at: 5)
        #expect(try typed.step())
        #expect(columnText(typed, at: 0) == "null")
        #expect(sqlite3_column_int64(typed.handle, 1) == 42)
        #expect(sqlite3_column_double(typed.handle, 2) == 3.5)
        #expect(columnText(typed, at: 3) == "bound text")
        #expect(sqlite3_column_int(typed.handle, 4) == 3)
    }

    @Test
    func errorPathsFinalizeStatementsAndConnectionCanClose() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)
        guard let handle = connection.handle else {
            Issue.record("read-only connection did not expose an open handle")
            return
        }

        do {
            let statement = try connection.prepare("INSERT INTO items(value) VALUES (?)")
            try statement.bind("synthetic private-looking value", at: 1)
            do {
                _ = try statement.step()
                Issue.record("expected read-only step to fail")
            } catch let error as SQLiteError {
                #expect(error.description.contains("synthetic private-looking value") == false)
            }
        }

        #expect(sqlite3_next_stmt(handle, nil) == nil)
        try connection.close()
        #expect(connection.handle == nil)
    }

    private func makeFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("fixture.sqlite")

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: openResult, handle: database)
        }
        defer { sqlite3_close(database) }

        let sql = """
        CREATE TABLE items(value TEXT);
        INSERT INTO items(value) VALUES
            ('plain'),
            ('O''Reilly'),
            ('100% literal'),
            ('under_score'),
            ('back\\slash');
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
        return databaseURL
    }

    private func columnText(_ statement: SQLiteStatement, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement.handle, index) else { return nil }
        return String(cString: text)
    }
}

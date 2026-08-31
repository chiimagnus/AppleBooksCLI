import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("SQLiteRestoreTests")
struct SQLiteRestoreTests {
    @Test
    func restoresThroughSQLiteBackupWithWALAndOpenReader() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "snapshot", large: false)
        let backupRoot = root.appendingPathComponent("backups")
        let restoreSource = try SQLiteBackup.create(source: destination, backupRoot: backupRoot, keep: 10)
        try enableWALAndSetValue(destination, value: "current")

        let openReader = try SQLiteConnection.readOnly(path: destination.path)
        #expect(try readValue(using: openReader) == "current")

        try SQLiteBackup.restore(
            backup: restoreSource,
            destination: destination,
            backupRoot: backupRoot,
            keep: 10,
            environment: .test(booksRunning: false)
        )

        try openReader.close()
        try SQLiteBackup.verifyIntegrity(of: destination)
        #expect(try readValue(at: destination) == "snapshot")
        let backups = try completedBackups(in: backupRoot, stem: "BKLibrary")
        #expect(backups.count == 2)
        #expect(try backups.contains { try readValue(at: $0) == "current" })
    }

    @Test
    func booksRunningRejectsBeforeSafetyBackupOrDestinationWrite() throws {
        let fixture = try restoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let countBefore = try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count

        #expect(throws: SQLiteBackupError.booksRunning) {
            try SQLiteBackup.restore(
                backup: fixture.backup,
                destination: fixture.destination,
                backupRoot: fixture.backupRoot,
                environment: .test(booksRunning: true)
            )
        }
        #expect(try readValue(at: fixture.destination) == "current")
        #expect(try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count == countBefore)
    }

    @Test
    func corruptOrUnownedRestoreSourceFailsBeforeDestinationMutation() throws {
        let fixture = try restoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corrupt = fixture.backupRoot.appendingPathComponent(
            BackupMetadata.fresh(sourceStem: "BKLibrary").filename
        )
        try Data("not sqlite".utf8).write(to: corrupt)
        let external = fixture.root.appendingPathComponent(fixture.backup.lastPathComponent)
        try FileManager.default.copyItem(at: fixture.backup, to: external)

        #expect(throws: (any Error).self) {
            try SQLiteBackup.restore(
                backup: corrupt,
                destination: fixture.destination,
                backupRoot: fixture.backupRoot,
                environment: .test(booksRunning: false)
            )
        }
        #expect(throws: SQLiteBackupError.invalidRestoreSource) {
            try SQLiteBackup.restore(
                backup: external,
                destination: fixture.destination,
                backupRoot: fixture.backupRoot,
                environment: .test(booksRunning: false)
            )
        }
        #expect(try readValue(at: fixture.destination) == "current")
    }

    @Test
    func preBackupFailureLeavesDestinationUntouched() throws {
        let fixture = try restoreFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: SQLiteBackupError.invalidRetention) {
            try SQLiteBackup.restore(
                backup: fixture.backup,
                destination: fixture.destination,
                backupRoot: fixture.backupRoot,
                keep: 0,
                environment: .test(booksRunning: false)
            )
        }
        #expect(try readValue(at: fixture.destination) == "current")
    }

    @Test
    func midRestoreFailureRollsBackPartialBackupTransaction() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "snapshot", large: true)
        let backupRoot = root.appendingPathComponent("backups")
        let restoreSource = try SQLiteBackup.create(source: destination, backupRoot: backupRoot)
        try setValue(destination, value: "current")

        #expect(throws: SQLiteBackupError.restoreFailed(SQLITE_INTERRUPT)) {
            try SQLiteBackup.restore(
                backup: restoreSource,
                destination: destination,
                backupRoot: backupRoot,
                environment: .test(booksRunning: false, pageCount: 1, failAfterSteps: 1)
            )
        }
        #expect(try readValue(at: destination) == "current")
        try SQLiteBackup.verifyIntegrity(of: destination)
    }

    private func restoreFixture() throws -> RestoreFixture {
        let root = temporaryDirectory()
        let destination = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "snapshot", large: false)
        let backupRoot = root.appendingPathComponent("backups")
        let backup = try SQLiteBackup.create(source: destination, backupRoot: backupRoot)
        try setValue(destination, value: "current")
        return RestoreFixture(root: root, destination: destination, backupRoot: backupRoot, backup: backup)
    }

    private func database(at url: URL, value: String, large: Bool) throws -> URL {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else { throw SQLiteError.current(operation: .open, code: open, handle: handle) }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE sample(value TEXT); CREATE TABLE padding(value BLOB);", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        try execute(handle, sql: "INSERT INTO sample VALUES(?)", text: value)
        if large {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO padding VALUES(zeroblob(1048576))", -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
        }
        return url
    }

    private func enableWALAndSetValue(_ url: URL, value: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        try execute(handle, sql: "UPDATE sample SET value=?", text: value)
    }

    private func setValue(_ url: URL, value: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close(handle) }
        try execute(handle, sql: "UPDATE sample SET value=?", text: value)
    }

    private func execute(_ handle: OpaquePointer, sql: String, text: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        let bind = text.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func readValue(at url: URL) throws -> String? {
        try readValue(using: SQLiteConnection.readOnly(path: url.path))
    }

    private func readValue(using connection: SQLiteConnection) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func completedBackups(in root: URL, stem: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { BackupMetadata.parse(filename: $0.lastPathComponent, sourceStem: stem) != nil }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct RestoreFixture {
        let root: URL
        let destination: URL
        let backupRoot: URL
        let backup: URL
    }
}

private extension RestoreEnvironment {
    static func test(
        booksRunning: Bool,
        pageCount: Int32 = -1,
        failAfterSteps: Int? = nil
    ) -> RestoreEnvironment {
        RestoreEnvironment(
            booksIsRunning: { booksRunning },
            pageCount: pageCount,
            failAfterSteps: failAfterSteps
        )
    }
}

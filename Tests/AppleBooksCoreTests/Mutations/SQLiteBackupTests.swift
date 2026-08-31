import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("SQLiteBackupTests")
struct SQLiteBackupTests {
    @Test
    func createsFreshIntegrityCheckedOnlineBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "first")
        let backupRoot = root.appendingPathComponent("backups")

        let first = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 10)
        let second = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 10)

        #expect(first != second)
        #expect(try storedValue(in: first) == "first")
        #expect(try storedValue(in: second) == "first")
        #expect(BackupMetadata.parse(filename: first.lastPathComponent, sourceStem: "BKLibrary") != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).contains { $0.hasSuffix(".part") } == false)
    }

    @Test
    func walSourceProducesStandaloneReadOnlyBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "before")
        let backupRoot = root.appendingPathComponent("backups")

        var writer: OpaquePointer?
        guard sqlite3_open(source.path, &writer) == SQLITE_OK, let writer else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        guard sqlite3_exec(writer, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(writer, "UPDATE sample SET value='after'", nil, nil, nil) == SQLITE_OK else {
            let error = SQLiteError.current(operation: .step, code: sqlite3_errcode(writer), handle: writer)
            sqlite3_close_v2(writer)
            throw error
        }
        sqlite3_close_v2(writer)

        let openReader = try SQLiteConnection.readOnly(path: source.path)
        #expect(try storedValue(using: openReader) == "after")
        let backup = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 10)
        try openReader.close()

        #expect(try storedValue(in: backup) == "after")
        #expect(FileManager.default.fileExists(atPath: backup.path + "-wal") == false)
        #expect(FileManager.default.fileExists(atPath: backup.path + "-shm") == false)
    }

    @Test
    func retentionKeepsNewestCompletedBackupsAndOnlyOwnsSameStemParts() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "value")
        let backupRoot = root.appendingPathComponent("backups")
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let unrelated = backupRoot.appendingPathComponent("notes.txt")
        let otherStem = backupRoot.appendingPathComponent("AEAnnotation__20260101-000000-000000__00000000-0000-0000-0000-000000000001.sqlite.part")
        try Data("keep".utf8).write(to: unrelated)
        try Data("keep".utf8).write(to: otherStem)

        let first = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 2)
        let ownPart = URL(fileURLWithPath: first.path + ".part")
        try Data("stale".utf8).write(to: ownPart)
        _ = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 2)
        _ = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 2)

        let names = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
        #expect(names.filter { BackupMetadata.parse(filename: $0, sourceStem: "BKLibrary") != nil }.count == 2)
        #expect(FileManager.default.fileExists(atPath: ownPart.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: otherStem.path))
    }

    @Test
    func exclusivePublishNeverOverwritesCompletedBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let part = root.appendingPathComponent("candidate.sqlite.part")
        let final = root.appendingPathComponent("completed.sqlite")
        try Data("new".utf8).write(to: part)
        try Data("old".utf8).write(to: final)

        #expect(throws: SQLiteBackupError.filesystemFailure) {
            try SQLiteBackup.publish(part: part, final: final)
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "old")
        #expect(FileManager.default.fileExists(atPath: part.path) == false)
    }

    @Test
    func invalidRetentionRejectsBeforeFilesystemWrite() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "value")
        let backupRoot = root.appendingPathComponent("must-not-exist")

        #expect(throws: SQLiteBackupError.invalidRetention) {
            _ = try SQLiteBackup.create(source: source, backupRoot: backupRoot, keep: 0)
        }
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
    }

    @Test
    func failedBackupDoesNotPublishOrLeavePart() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BKLibrary.sqlite")
        try Data("not a sqlite database".utf8).write(to: source)
        let backupRoot = root.appendingPathComponent("backups")

        #expect(throws: (any Error).self) {
            _ = try SQLiteBackup.create(source: source, backupRoot: backupRoot)
        }
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).isEmpty)
        }
    }

    private func database(at url: URL, value: String) throws -> URL {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else { throw SQLiteError.current(operation: .open, code: open, handle: handle) }
        defer { sqlite3_close(handle) }
        let sql = "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES(?);"
        let create = sqlite3_exec(handle, "CREATE TABLE sample(value TEXT)", nil, nil, nil)
        guard create == SQLITE_OK else { throw SQLiteError.current(operation: .step, code: create, handle: handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO sample VALUES(?)", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle) }
        _ = sql
        return url
    }

    private func storedValue(in url: URL) throws -> String? {
        try storedValue(using: SQLiteConnection.readOnly(path: url.path))
    }

    private func storedValue(using connection: SQLiteConnection) throws -> String? {
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

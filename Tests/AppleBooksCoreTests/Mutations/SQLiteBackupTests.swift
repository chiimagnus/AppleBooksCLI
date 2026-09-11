import Darwin
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
    func retentionStreamsLargeDirectoryKeepsTopKPlusPreservedAndIgnoresUnownedEntries() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BKLibrary.sqlite")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let count = 100_001
        var preserved = ""
        for index in 0..<count {
            let name = retentionFilename(index: index)
            if index == 0 { preserved = name }
            let path = backupRoot.appendingPathComponent(name).path
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            #expect(descriptor >= 0)
            if descriptor >= 0 { close(descriptor) }
        }

        let malformed = backupRoot.appendingPathComponent("BKLibrary__not-a-backup.sqlite")
        let otherStem = backupRoot.appendingPathComponent("AEAnnotation__20260101-000000-000000__00000000-0000-0000-0000-000000000001.sqlite")
        let ownPart = backupRoot.appendingPathComponent(retentionFilename(index: count + 1) + ".part")
        let symlinkName = retentionFilename(index: count + 2)
        let directoryName = retentionFilename(index: count + 3)
        try Data().write(to: malformed)
        try Data().write(to: otherStem)
        try Data().write(to: ownPart)
        try FileManager.default.createSymbolicLink(
            at: backupRoot.appendingPathComponent(symlinkName),
            withDestinationURL: malformed
        )
        try FileManager.default.createDirectory(
            at: backupRoot.appendingPathComponent(directoryName),
            withIntermediateDirectories: false
        )

        let instrumentation = BackupRetentionInstrumentation()
        try SQLiteBackup.enforceRetention(
            source: source,
            backupRoot: backupRoot,
            keep: 10,
            preserving: [preserved],
            instrumentation: instrumentation
        )

        let names = try FileManager.default.contentsOfDirectory(atPath: backupRoot.path)
        let retainedRegular = names.filter { name in
            guard BackupMetadata.parse(filename: name, sourceStem: "BKLibrary") != nil else { return false }
            var metadata = stat()
            return lstat(backupRoot.appendingPathComponent(name).path, &metadata) == 0
                && metadata.st_mode & S_IFMT == S_IFREG
        }
        #expect(retainedRegular.count == 11)
        #expect(retainedRegular.contains(preserved))
        for index in (count - 10)..<count {
            #expect(retainedRegular.contains(retentionFilename(index: index)))
        }
        #expect(instrumentation.retainedCandidatePeak == 10)
        #expect(instrumentation.scannedEntryCount > 100_000)
        #expect(FileManager.default.fileExists(atPath: ownPart.path) == false)
        #expect(FileManager.default.fileExists(atPath: malformed.path))
        #expect(FileManager.default.fileExists(atPath: otherStem.path))
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(symlinkName).path))
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(directoryName).path))
    }

    @Test
    func retentionNeverDeletesNewerBackupPublishedBetweenStreamingPasses() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BKLibrary.sqlite")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let older = retentionFilename(index: 0)
        let newer = retentionFilename(index: 1)
        try Data().write(to: backupRoot.appendingPathComponent(older))

        try SQLiteBackup.enforceRetention(
            source: source,
            backupRoot: backupRoot,
            keep: 1,
            betweenPasses: {
                try Data().write(to: backupRoot.appendingPathComponent(newer))
            }
        )

        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(newer).path))
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(older).path))

        try SQLiteBackup.enforceRetention(source: source, backupRoot: backupRoot, keep: 1)
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(newer).path))
        #expect(FileManager.default.fileExists(atPath: backupRoot.appendingPathComponent(older).path) == false)
    }

    @Test
    func backupRootMutationLockSerializesPublishAndRetentionOwners() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let first = try BackupRootGuard.create(backupRoot)
        let existing = try BackupRootGuard.openExisting(backupRoot)
        let second = try #require(existing)

        try first.withExclusiveMutationLock {
            errno = 0
            #expect(flock(second.descriptor, LOCK_EX | LOCK_NB) == -1)
            #expect(errno == EWOULDBLOCK)
        }

        #expect(flock(second.descriptor, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(second.descriptor, LOCK_UN) == 0)
    }

    @Test
    func retentionFailsClosedWhenRootIdentityChangesBetweenStreamingPasses() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("BKLibrary.sqlite")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        for index in 0..<3 {
            try Data().write(to: backupRoot.appendingPathComponent(retentionFilename(index: index)))
        }
        let original = root.appendingPathComponent("backups-original", isDirectory: true)

        #expect(throws: SQLiteBackupError.filesystemFailure) {
            try SQLiteBackup.enforceRetention(
                source: source,
                backupRoot: backupRoot,
                keep: 1,
                betweenPasses: {
                    try FileManager.default.moveItem(at: backupRoot, to: original)
                    try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: false)
                }
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).count == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).isEmpty)
    }

    @Test
    func exclusivePublishNeverOverwritesCompletedBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("candidate.sqlite")
        let final = root.appendingPathComponent("completed.sqlite")
        try Data("new".utf8).write(to: staging)
        try Data("old".utf8).write(to: final)
        let guardRoot = try BackupRootGuard.create(root)

        #expect(throws: SQLiteBackupError.filesystemFailure) {
            try guardRoot.publish(staging: staging, finalName: final.lastPathComponent)
        }
        #expect(try String(contentsOf: final, encoding: .utf8) == "old")
        #expect(FileManager.default.fileExists(atPath: final.path + ".part") == false)
    }

    @Test
    func backupRootRejectsRootAndIntermediateSymlinksWithoutTouchingTargets() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "value")
        let realRoot = root.appendingPathComponent("real-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: false)
        let rootLink = root.appendingPathComponent("backup-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realRoot)

        #expect(throws: SQLiteBackupError.filesystemFailure) {
            _ = try SQLiteBackup.create(source: source, backupRoot: rootLink)
        }
        #expect(throws: SQLiteBackupError.filesystemFailure) {
            _ = try SQLiteBackup.list(source: source, backupRoot: rootLink)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: realRoot.path).isEmpty)

        let realParent = root.appendingPathComponent("real-parent", isDirectory: true)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        let parentLink = root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: realParent)
        let nested = parentLink.appendingPathComponent("nested/backups", isDirectory: true)
        #expect(throws: SQLiteBackupError.filesystemFailure) {
            _ = try SQLiteBackup.create(source: source, backupRoot: nested)
        }
        #expect(FileManager.default.fileExists(atPath: realParent.appendingPathComponent("nested").path) == false)
    }

    @Test
    func backupRootCreatesMissingNestedDirectoriesWithoutFollowingPaths() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "value")
        let backupRoot = root.appendingPathComponent("a/b/c", isDirectory: true)

        let backup = try SQLiteBackup.create(source: source, backupRoot: backupRoot)

        #expect(try storedValue(in: backup) == "value")
        #expect(backup.deletingLastPathComponent().standardizedFileURL == backupRoot.standardizedFileURL)
    }

    @Test
    func validatedRootDetectsPathReplacementAndNeverWritesIntoReplacement() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let guardRoot = try BackupRootGuard.create(backupRoot)
        let original = root.appendingPathComponent("backups-original", isDirectory: true)
        try FileManager.default.moveItem(at: backupRoot, to: original)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: false)
        let staging = root.appendingPathComponent("staging.sqlite")
        try Data("payload".utf8).write(to: staging)

        #expect(throws: SQLiteBackupError.filesystemFailure) {
            try guardRoot.validateCurrentPathIdentity()
        }
        #expect(throws: SQLiteBackupError.filesystemFailure) {
            try guardRoot.publish(staging: staging, finalName: "owned.sqlite")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backupRoot.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
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

    private func retentionFilename(index: Int) -> String {
        let hex = String(format: "%012llx", UInt64(index))
        return "BKLibrary__20260101-000000-000000__00000000-0000-0000-0000-\(hex).sqlite"
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

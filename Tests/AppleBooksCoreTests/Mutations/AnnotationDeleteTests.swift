import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationDeleteTests")
struct AnnotationDeleteTests {
    @Test
    func localPKSoftDeletePreservesRowAndUserFields() throws {
        let fixture = try fixture()
        defer { fixture.remove() }

        let result = try fixture.writer.delete(localPK: 1)

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.localPK == 1)
        #expect(result.stableID == nil)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try integer(fixture.database, "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZAEANNOTATION WHERE Z_PK=1") == 4)
        #expect(try double(fixture.database, "SELECT ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try double(fixture.database, "SELECT ZFUTUREPROOFING6 FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "keep-note")
        #expect(try text(fixture.database, "SELECT ZANNOTATIONSELECTEDTEXT FROM ZAEANNOTATION WHERE Z_PK=1") == "keep-selected")
    }

    @Test
    func uuidSoftDeleteReturnsStableIdentity() throws {
        let fixture = try fixture()
        defer { fixture.remove() }

        let result = try fixture.writer.delete(uuid: "uuid-1")

        #expect(result.localPK == 1)
        #expect(result.stableID == "uuid-1")
        #expect(BackupMetadata.parse(filename: result.backupHandle, sourceStem: "annotations") != nil)
    }

    @Test
    func deletedUnknownMissingAndDuplicateTargetsFailBeforeBackup() throws {
        for deleted in [Int64(1), Int64(2)] {
            let blocked = try fixture(deleted: deleted)
            defer { blocked.remove() }
            #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
                _ = try blocked.writer.delete(localPK: 1)
            }
            #expect(FileManager.default.fileExists(atPath: blocked.backupRoot.path) == false)
        }

        let nullDeleted = try fixture(deleted: nil)
        defer { nullDeleted.remove() }
        #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
            _ = try nullDeleted.writer.delete(localPK: 1)
        }
        #expect(FileManager.default.fileExists(atPath: nullDeleted.backupRoot.path) == false)

        let missing = try fixture()
        defer { missing.remove() }
        #expect(throws: AnnotationWriteError.annotationMissing) {
            _ = try missing.writer.delete(localPK: 999)
        }
        #expect(FileManager.default.fileExists(atPath: missing.backupRoot.path) == false)

        let duplicate = try fixture(duplicateUUID: true)
        defer { duplicate.remove() }
        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try duplicate.writer.delete(uuid: "uuid-1")
        }
        #expect(FileManager.default.fileExists(atPath: duplicate.backupRoot.path) == false)
    }

    @Test
    func failedDeleteUpdateRollsBackAndKeepsRestorePoint() throws {
        let fixture = try fixture(blockDeleteUpdate: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.writer.delete(localPK: 1)
            Issue.record("expected mutation failure")
        } catch let error as MutationFailure {
            #expect(error.code == .mutationFailed)
            #expect(error.backupHandle != nil)
        }

        #expect(try integer(fixture.database, "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 0)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZAEANNOTATION WHERE Z_PK=1") == 3)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "keep-note")
        #expect(try completedBackups(fixture.backupRoot).count == 1)
    }

    @Test
    func facadeRoutesBothDeleteSelectors() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let library = fixture.root.appendingPathComponent("library.sqlite")
        try execute(library, "CREATE TABLE placeholder(value INTEGER)")
        let config = fixture.root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let closed = closedController()
        let books = try AppleBooks(
            libraryDB: library,
            annotationsDB: fixture.database,
            configurationFile: config,
            collectionWriter: CollectionWriter(database: library, backupRoot: fixture.root.appendingPathComponent("library-backups"), booksApp: closed),
            annotationWriter: fixture.writer
        )

        let byUUID = try books.deleteAnnotation(uuid: "uuid-1")
        #expect(byUUID.stableID == "uuid-1")
        try execute(fixture.database, "UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=0 WHERE Z_PK=1")
        let byPK = try books.deleteAnnotation(localPK: 1)
        #expect(byPK.localPK == 1)
        #expect(byPK.stableID == nil)
    }

    private func fixture(
        deleted: Int64? = 0,
        duplicateUUID: Bool = false,
        blockDeleteUpdate: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("annotations.sqlite")
        try execute(database, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,99)")
        try execute(database, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              Z_ENT INTEGER,
              Z_OPT INTEGER,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZFUTUREPROOFING6 TEXT
            )
            """)
        let deletedSQL = deleted.map(String.init) ?? "NULL"
        try execute(database, "INSERT INTO ZAEANNOTATION VALUES(1,17,3,\(deletedSQL),'uuid-1','keep-note',1,'keep-selected','1')")
        if duplicateUUID {
            try execute(database, "INSERT INTO ZAEANNOTATION VALUES(2,17,1,0,'uuid-1','other',1,'other-selected','1')")
        }
        if blockDeleteUpdate {
            try execute(database, """
                CREATE TRIGGER block_annotation_delete
                BEFORE UPDATE OF ZANNOTATIONDELETED ON ZAEANNOTATION
                WHEN NEW.ZANNOTATIONDELETED=1
                BEGIN SELECT RAISE(ABORT,'blocked'); END
                """)
        }
        let backupRoot = root.appendingPathComponent("backups")
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            writer: AnnotationWriter(database: database, backupRoot: backupRoot, booksApp: closedController())
        )
    }

    private func closedController() -> BooksAppController {
        BooksAppController(
            isRunning: { false },
            terminate: { true },
            launch: {},
            sleep: { _ in }
        )
    }

    private func execute(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func integer(_ database: URL, _ sql: String) throws -> Int64 {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return 0 }
        return sqlite3_column_int64(statement.handle, 0)
    }

    private func double(_ database: URL, _ sql: String) throws -> Double {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return 0 }
        return sqlite3_column_double(statement.handle, 0)
    }

    private func text(_ database: URL, _ sql: String) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step(), let raw = sqlite3_column_text(statement.handle, 0) else { return nil }
        return String(cString: raw)
    }

    private func completedBackups(_ root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { BackupMetadata.parse(filename: $0.lastPathComponent, sourceStem: "annotations") != nil }
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let writer: AnnotationWriter

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

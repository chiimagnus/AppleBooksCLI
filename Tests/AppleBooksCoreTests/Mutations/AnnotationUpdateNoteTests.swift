import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationUpdateNoteTests")
struct AnnotationUpdateNoteTests {
    @Test
    func uuidUpdatePreservesUserTextAndCoreDataInvariants() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let note = "  spaced\nnote  "

        let result = try fixture.writer.updateNote(uuid: "uuid-1", note: note)

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.localPK == 1)
        #expect(result.stableID == "uuid-1")
        #expect(result.warnings.isEmpty)
        #expect(BackupMetadata.parse(filename: result.backupHandle, sourceStem: "annotations") != nil)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == note)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=3") == "upper-note")
        #expect(try text(fixture.database, "SELECT ZANNOTATIONSELECTEDTEXT FROM ZAEANNOTATION WHERE Z_PK=1") == "keep-selected")
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZAEANNOTATION WHERE Z_PK=1") == 4)
        #expect(try double(fixture.database, "SELECT ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try double(fixture.database, "SELECT ZFUTUREPROOFING6 FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 99)
    }

    @Test
    func localPKIsExplicitAndWhitespaceNoteIsNotTrimmed() throws {
        let fixture = try fixture()
        defer { fixture.remove() }

        let result = try fixture.writer.updateNote(localPK: 1, note: " ")

        #expect(result.localPK == 1)
        #expect(result.stableID == nil)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == " ")
    }

    @Test
    func noteLengthIsValidatedBeforeBackup() throws {
        let empty = try fixture()
        defer { empty.remove() }
        #expect(throws: AnnotationWriteError.invalidNoteLength) {
            _ = try empty.writer.updateNote(localPK: 1, note: "")
        }
        #expect(FileManager.default.fileExists(atPath: empty.backupRoot.path) == false)

        let tooLong = try fixture()
        defer { tooLong.remove() }
        #expect(throws: AnnotationWriteError.invalidNoteLength) {
            _ = try tooLong.writer.updateNote(localPK: 1, note: String(repeating: "x", count: 10_001))
        }
        #expect(FileManager.default.fileExists(atPath: tooLong.backupRoot.path) == false)

        let boundary = try fixture()
        defer { boundary.remove() }
        let result = try boundary.writer.updateNote(localPK: 1, note: String(repeating: "x", count: 10_000))
        #expect(result.changed)
    }

    @Test
    func duplicateDeletedUnknownAndEntityMismatchFailClosedBeforeBackup() throws {
        let duplicate = try fixture(duplicateUUID: true)
        defer { duplicate.remove() }
        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try duplicate.writer.updateNote(uuid: "uuid-1", note: "new")
        }
        #expect(FileManager.default.fileExists(atPath: duplicate.backupRoot.path) == false)

        for deleted in [Int64(1), Int64(2)] {
            let blocked = try fixture(deleted: deleted)
            defer { blocked.remove() }
            #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
                _ = try blocked.writer.updateNote(localPK: 1, note: "new")
            }
            #expect(FileManager.default.fileExists(atPath: blocked.backupRoot.path) == false)
        }

        let nullDeleted = try fixture(deleted: nil)
        defer { nullDeleted.remove() }
        #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
            _ = try nullDeleted.writer.updateNote(localPK: 1, note: "new")
        }
        #expect(FileManager.default.fileExists(atPath: nullDeleted.backupRoot.path) == false)

        let mismatch = try fixture(entityID: 999)
        defer { mismatch.remove() }
        #expect(throws: WriteSchemaGuardError.entityMismatch("ZAEANNOTATION")) {
            _ = try mismatch.writer.updateNote(localPK: 1, note: "new")
        }
        #expect(FileManager.default.fileExists(atPath: mismatch.backupRoot.path) == false)
    }

    @Test
    func transactionRevalidationRejectsStateChangedDuringBooksQuit() throws {
        let root = try baseFixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("annotations.sqlite")
        try createSchema(at: database, deleted: 0, entityID: 17, duplicateUUID: false)
        let backupRoot = root.appendingPathComponent("backups")
        var running = true
        var launches = 0
        let controller = BooksAppController(
            isRunning: { running },
            terminate: {
                let changed = executeNoThrow(database, "UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1 WHERE Z_PK=1")
                running = false
                return changed
            },
            launch: {
                launches += 1
                running = true
            },
            sleep: { _ in }
        )
        let writer = AnnotationWriter(database: database, backupRoot: backupRoot, booksApp: controller)

        do {
            _ = try writer.updateNote(localPK: 1, note: "must-not-write")
            Issue.record("expected transaction revalidation failure")
        } catch let error as MutationFailure {
            #expect(error.code == .revalidateFailed)
            #expect(error.backupHandle != nil)
        }
        #expect(launches == 1)
        #expect(running)
        #expect(try text(database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "old-note")
        #expect(try integer(database, "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try completedBackups(backupRoot).count == 1)
    }

    @Test
    func facadeRoutesBothExplicitSelectorsToAnnotationWriter() throws {
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

        let byUUID = try books.updateAnnotationNote(uuid: "uuid-1", note: "uuid-note")
        #expect(byUUID.localPK == 1)
        #expect(byUUID.stableID == "uuid-1")
        let byPK = try books.updateAnnotationNote(localPK: 1, note: "pk-note")
        #expect(byPK.localPK == 1)
        #expect(byPK.stableID == nil)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "pk-note")
    }

    private func fixture(
        deleted: Int64? = 0,
        entityID: Int64 = 17,
        duplicateUUID: Bool = false
    ) throws -> Fixture {
        let root = try baseFixtureRoot()
        let database = root.appendingPathComponent("annotations.sqlite")
        try createSchema(at: database, deleted: deleted, entityID: entityID, duplicateUUID: duplicateUUID)
        let backupRoot = root.appendingPathComponent("backups")
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            writer: AnnotationWriter(database: database, backupRoot: backupRoot, booksApp: closedController())
        )
    }

    private func baseFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func createSchema(at database: URL, deleted: Int64?, entityID: Int64, duplicateUUID: Bool) throws {
        try execute(database, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,99)")
        try execute(database, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              Z_ENT INTEGER,
              Z_OPT INTEGER,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONUUID TEXT COLLATE NOCASE,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZFUTUREPROOFING6 TEXT
            )
            """)
        let deletedSQL = deleted.map(String.init) ?? "NULL"
        try execute(database, "INSERT INTO ZAEANNOTATION VALUES(1,\(entityID),3,\(deletedSQL),'uuid-1','old-note',1,'keep-selected','1')")
        try execute(database, "INSERT INTO ZAEANNOTATION VALUES(3,17,1,0,'UUID-1','upper-note',1,'upper-selected','1')")
        if duplicateUUID {
            try execute(database, "INSERT INTO ZAEANNOTATION VALUES(2,17,1,0,'uuid-1','other',1,'other-selected','1')")
        }
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

    private func executeNoThrow(_ database: URL, _ sql: String) -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { return false }
        defer { sqlite3_close_v2(handle) }
        return sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK
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

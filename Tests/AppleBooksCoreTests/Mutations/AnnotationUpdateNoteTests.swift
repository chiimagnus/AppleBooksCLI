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
        #expect(result.backupHandle.flatMap { BackupMetadata.parse(filename: $0, sourceStem: "annotations") } != nil)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == note)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=3") == "upper-note")
        #expect(try text(fixture.database, "SELECT ZANNOTATIONSELECTEDTEXT FROM ZAEANNOTATION WHERE Z_PK=1") == "keep-selected")
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZAEANNOTATION WHERE Z_PK=1") == 4)
        #expect(try double(fixture.database, "SELECT ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try double(fixture.database, "SELECT ZFUTUREPROOFING6 FROM ZAEANNOTATION WHERE Z_PK=1") > 1)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='AEAnnotation'") == 99)
    }

    @Test
    func embeddedNULNoteRoundTripsWithoutTruncation() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        let note = "before\0after"

        let result = try fixture.writer.updateNote(localPK: 1, note: note)

        #expect(result.changed)
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == note)
    }

    @Test
    func writerDerivesDeeplinkFromAnnotationStoreWithoutLibraryOrConfiguration() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try execute(fixture.database, "ALTER TABLE ZAEANNOTATION ADD COLUMN ZANNOTATIONASSETID TEXT")
        try execute(fixture.database, "ALTER TABLE ZAEANNOTATION ADD COLUMN ZANNOTATIONLOCATION TEXT")
        try execute(
            fixture.database,
            "UPDATE ZAEANNOTATION SET ZANNOTATIONASSETID='asset-synthetic', ZANNOTATIONLOCATION='epubcfi(/6/2[chapter]!/4/2,:1,:2)' WHERE Z_PK=1"
        )

        let result = try fixture.writer.updateNote(uuid: "uuid-1", note: "new note")

        #expect(result.appleBooksURL == "ibooks://assetid/asset-synthetic#epubcfi(/6/2%5Bchapter%5D!/4/2,:1,:2)")
    }

    @Test
    func oversizedCFIDegradesFocusWithoutReadingUnrelatedAnnotationBody() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try execute(fixture.database, "ALTER TABLE ZAEANNOTATION ADD COLUMN ZANNOTATIONASSETID TEXT")
        try execute(fixture.database, "ALTER TABLE ZAEANNOTATION ADD COLUMN ZANNOTATIONLOCATION TEXT")

        let oversizedCFI = oversizedCFI()
        var handle: OpaquePointer?
        guard sqlite3_open(fixture.database.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        do {
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "UPDATE ZAEANNOTATION SET ZANNOTATIONASSETID=?,ZANNOTATIONLOCATION=?,ZANNOTATIONSELECTEDTEXT=CAST(X'80' AS TEXT) WHERE Z_PK=1",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement else {
                throw AnnotationWriteError.writeFailed
            }
            defer { sqlite3_finalize(statement) }
            guard bindSQLiteText("asset-synthetic", to: statement, at: 1) == SQLITE_OK,
                  bindSQLiteText(oversizedCFI, to: statement, at: 2) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw AnnotationWriteError.writeFailed
            }
        }

        let result = try fixture.writer.updateNote(uuid: "uuid-1", note: "new note")

        #expect(result.appleBooksURL == "ibooks://assetid/asset-synthetic")
        #expect(try text(fixture.database, "SELECT ZANNOTATIONLOCATION FROM ZAEANNOTATION WHERE Z_PK=1") == oversizedCFI)
        #expect(try text(fixture.database, "SELECT hex(ZANNOTATIONSELECTEDTEXT) FROM ZAEANNOTATION WHERE Z_PK=1") == "80")
    }

    @Test
    func whitespaceOnlyNoteIsRejectedButMeaningfulWhitespaceIsPreserved() throws {
        let rejected = try fixture()
        defer { rejected.remove() }
        #expect(throws: AnnotationWriteError.invalidNoteLength) {
            _ = try rejected.writer.updateNote(localPK: 1, note: " \t\r\n")
        }
        #expect(FileManager.default.fileExists(atPath: rejected.backupRoot.path) == false)

        let preserved = try fixture()
        defer { preserved.remove() }
        let note = "  kept\ntext  "
        let result = try preserved.writer.updateNote(localPK: 1, note: note)
        #expect(result.localPK == 1)
        #expect(result.stableID == "uuid-1")
        #expect(try text(preserved.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == note)
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

        let byteOverflow = try fixture()
        defer { byteOverflow.remove() }
        let oneOversizedGrapheme = "a" + String(repeating: "\u{0301}", count: 32_768)
        #expect(oneOversizedGrapheme.count == 1)
        #expect(oneOversizedGrapheme.utf8.count > 64 * 1_024)
        #expect(throws: AnnotationWriteError.invalidNoteLength) {
            _ = try byteOverflow.writer.updateNote(localPK: 1, note: oneOversizedGrapheme)
        }
        #expect(FileManager.default.fileExists(atPath: byteOverflow.backupRoot.path) == false)
    }

    @Test
    func identicalTextAndIdenticalNullAreQuietNoOpsWhileClearStoresNull() throws {
        let textFixture = try fixture()
        defer { textFixture.remove() }
        let textNoOp = try textFixture.writer.updateNote(localPK: 1, note: "old-note", syncCloud: true)
        #expect(textNoOp.committed == false)
        #expect(textNoOp.changed == false)
        #expect(textNoOp.backupID == nil)
        #expect(textNoOp.acknowledgementRequested)
        #expect(textNoOp.acknowledged == nil)
        #expect(FileManager.default.fileExists(atPath: textFixture.backupRoot.path) == false)

        let clearFixture = try fixture()
        defer { clearFixture.remove() }
        let cleared = try clearFixture.writer.updateNote(localPK: 1, note: nil)
        #expect(cleared.committed)
        #expect(cleared.changed)
        #expect(try integer(clearFixture.database, "SELECT ZANNOTATIONNOTE IS NULL FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try completedBackups(clearFixture.backupRoot).count == 1)

        let clearNoOp = try clearFixture.writer.updateNote(localPK: 1, note: nil, syncCloud: true)
        #expect(clearNoOp.committed == false)
        #expect(clearNoOp.changed == false)
        #expect(clearNoOp.backupID == nil)
        #expect(clearNoOp.acknowledgementRequested)
        #expect(clearNoOp.acknowledged == nil)
        #expect(try completedBackups(clearFixture.backupRoot).count == 1)
    }

    @Test
    func uuidWriterRejectsTenThousandDuplicatesBeforeBackup() throws {
        let fixture = try fixture()
        defer { fixture.remove() }
        try execute(fixture.database, """
            WITH RECURSIVE seq(x) AS (
              VALUES(1000)
              UNION ALL
              SELECT x + 1 FROM seq WHERE x < 10999
            )
            INSERT INTO ZAEANNOTATION(
              Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONTYPE,ZANNOTATIONUUID,
              ZANNOTATIONNOTE,ZANNOTATIONMODIFICATIONDATE,ZANNOTATIONSELECTEDTEXT,ZFUTUREPROOFING6
            )
            SELECT x,17,1,0,2,'uuid-1','duplicate',1,'duplicate','1' FROM seq;
            """)

        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try fixture.writer.updateNote(uuid: "uuid-1", note: "must-not-write")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
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
    func nonUserAnnotationTypesFailClosedBeforeBackup() throws {
        let systemBookmark = try fixture()
        defer { systemBookmark.remove() }
        try execute(systemBookmark.database, "UPDATE ZAEANNOTATION SET ZANNOTATIONTYPE=3 WHERE Z_PK=1")
        #expect(throws: AnnotationWriteError.annotationNotWritable) {
            _ = try systemBookmark.writer.updateNote(localPK: 1, note: "must-not-write")
        }
        #expect(FileManager.default.fileExists(atPath: systemBookmark.backupRoot.path) == false)

        let nullType = try fixture()
        defer { nullType.remove() }
        try execute(nullType.database, "UPDATE ZAEANNOTATION SET ZANNOTATIONTYPE=NULL WHERE Z_PK=1")
        #expect(throws: AnnotationWriteError.annotationNotWritable) {
            _ = try nullType.writer.updateNote(localPK: 1, note: "must-not-write")
        }
        #expect(FileManager.default.fileExists(atPath: nullType.backupRoot.path) == false)

        let missingColumn = try fixture(includeTypeColumn: false)
        defer { missingColumn.remove() }
        #expect(throws: WriteSchemaGuardError.self) {
            _ = try missingColumn.writer.updateNote(localPK: 1, note: "must-not-write")
        }
        #expect(FileManager.default.fileExists(atPath: missingColumn.backupRoot.path) == false)
    }

    @Test
    func quietRevalidationRejectsStateChangedDuringBooksQuitBeforeBackup() throws {
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
            Issue.record("expected quiet-state revalidation failure")
        } catch let error as MutationFailure {
            #expect(error.code == .revalidateFailed)
            #expect(error.backupHandle == nil)
        }
        #expect(launches == 1)
        #expect(running)
        #expect(try text(database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "old-note")
        #expect(try integer(database, "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(FileManager.default.fileExists(atPath: backupRoot.path) == false)
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
        #expect(byPK.stableID == "uuid-1")
        #expect(try text(fixture.database, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "pk-note")
    }

    private func fixture(
        deleted: Int64? = 0,
        entityID: Int64 = 17,
        duplicateUUID: Bool = false,
        includeTypeColumn: Bool = true
    ) throws -> Fixture {
        let root = try baseFixtureRoot()
        let database = root.appendingPathComponent("annotations.sqlite")
        try createSchema(
            at: database,
            deleted: deleted,
            entityID: entityID,
            duplicateUUID: duplicateUUID,
            includeTypeColumn: includeTypeColumn
        )
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

    private func createSchema(
        at database: URL,
        deleted: Int64?,
        entityID: Int64,
        duplicateUUID: Bool,
        includeTypeColumn: Bool = true
    ) throws {
        try execute(database, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,99)")
        try execute(database, """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              Z_ENT INTEGER,
              Z_OPT INTEGER,
              ZANNOTATIONDELETED INTEGER,
              \(includeTypeColumn ? "ZANNOTATIONTYPE INTEGER," : "")
              ZANNOTATIONUUID TEXT COLLATE NOCASE,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZFUTUREPROOFING6 TEXT
            )
            """)
        let deletedSQL = deleted.map(String.init) ?? "NULL"
        let typeColumn = includeTypeColumn ? ",ZANNOTATIONTYPE" : ""
        let typeValue = includeTypeColumn ? ",2" : ""
        let columns = "Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED\(typeColumn),ZANNOTATIONUUID,ZANNOTATIONNOTE,ZANNOTATIONMODIFICATIONDATE,ZANNOTATIONSELECTEDTEXT,ZFUTUREPROOFING6"
        try execute(database, "INSERT INTO ZAEANNOTATION(\(columns)) VALUES(1,\(entityID),3,\(deletedSQL)\(typeValue),'uuid-1','old-note',1,'keep-selected','1')")
        try execute(database, "INSERT INTO ZAEANNOTATION(\(columns)) VALUES(3,17,1,0\(typeValue),'UUID-1','upper-note',1,'upper-selected','1')")
        if duplicateUUID {
            try execute(database, "INSERT INTO ZAEANNOTATION(\(columns)) VALUES(2,17,1,0\(typeValue),'uuid-1','other',1,'other-selected','1')")
        }
    }

    private func oversizedCFI() -> String {
        let prefix = "epubcfi(/6/2["
        let suffix = "]!/4/2,:1,:2)"
        let targetBytes = CFIResourcePolicy.maximumStructuralBytes + 1
        let fillerCount = targetBytes - prefix.utf8.count - suffix.utf8.count
        return prefix + String(repeating: "x", count: fillerCount) + suffix
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
        guard try statement.step(),
              let rawName = sqlite3_column_name(statement.handle, 0) else { return nil }
        return try SQLiteRow(statement: statement).text(String(cString: rawName))
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

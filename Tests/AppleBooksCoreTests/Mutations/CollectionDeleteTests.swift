import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionDeleteTests")
struct CollectionDeleteTests {
    @Test
    func deleteTombstonesCollectionAndCleansOnlyItsMembershipRows() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try fixture.writer.deleteCollection(localPK: 10)
        #expect(result.committed)
        #expect(result.changed)
        #expect(result.localPK == 10)
        #expect(result.warnings.isEmpty)

        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=10") == 1)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 4)
        let times = try doubles(fixture.database, "SELECT ZLASTMODIFICATION,ZLOCALMODDATE FROM ZBKCOLLECTION WHERE Z_PK=10")
        #expect(times.0 == times.1)
        #expect(times.0 > 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10") == 0)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET") == 2)
    }

    @Test
    func membershipDeleteFailureRollsBackCollectionTombstone() throws {
        let fixture = try fixture(blockMemberDelete: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try fixture.writer.deleteCollection(localPK: 10)
            Issue.record("expected mutation failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle != nil)
        }
        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=10") == 0)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 3)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10") == 2)
    }

    @Test
    func systemCollectionDeleteFailsBeforeBackup() throws {
        let fixture = try fixture(systemCollection: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try fixture.writer.deleteCollection(localPK: 10)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
    }

    private func fixture(blockMemberDelete: Bool = false, systemCollection: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let collectionID = systemCollection ? "Books_Collection_ID" : "550E8400-E29B-41D4-A716-446655440000"
        try execute(database, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(database, """
            CREATE TABLE ZBKCOLLECTION(
              Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZDELETEDFLAG INTEGER,ZHIDDEN INTEGER,
              ZPLACEHOLDER INTEGER,ZSORTKEY INTEGER,ZSORTMODE INTEGER,ZVIEWMODE INTEGER,ZLASTMODIFICATION REAL,
              ZLOCALMODDATE REAL,ZCOLLECTIONID TEXT,ZDETAILS TEXT,ZTITLE TEXT
            )
            """)
        try execute(database, "CREATE TABLE ZBKCOLLECTIONMEMBER(Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZSORTKEY INTEGER,ZASSET INTEGER,ZCOLLECTION INTEGER,ZLOCALMODDATE REAL,ZASSETID TEXT,ZTEMPORARYASSETID TEXT)")
        try execute(database, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT)")
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,20)")
        try execute(database, "INSERT INTO ZBKCOLLECTION VALUES(10,7,3,0,0,0,20000,6,NULL,1,1,'\(collectionID)','keep','Shelf')")
        try execute(database, "INSERT INTO ZBKCOLLECTION VALUES(20,7,1,0,0,0,30000,6,NULL,1,1,'550E8400-E29B-41D4-A716-446655440001',NULL,'Other')")
        try execute(database, "INSERT INTO ZBKLIBRARYASSET VALUES(1,'asset-1'),(2,'asset-2')")
        try execute(database, "INSERT INTO ZBKCOLLECTIONMEMBER VALUES(1,8,1,10000,1,10,1,'asset-1',NULL),(2,8,1,20000,2,10,1,'asset-2',NULL),(3,8,1,10000,1,20,1,'asset-1',NULL)")
        if blockMemberDelete {
            try execute(database, "CREATE TRIGGER block_member_delete BEFORE DELETE ON ZBKCOLLECTIONMEMBER BEGIN SELECT RAISE(ABORT,'blocked'); END")
        }
        let backupRoot = root.appendingPathComponent("backups")
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            writer: CollectionWriter(
                database: database,
                backupRoot: backupRoot,
                booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {})
            )
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
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return 0 }
        return sqlite3_column_int64(statement.handle, 0)
    }

    private func doubles(_ database: URL, _ sql: String) throws -> (Double, Double) {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return (0, 0) }
        return (sqlite3_column_double(statement.handle, 0), sqlite3_column_double(statement.handle, 1))
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let writer: CollectionWriter
    }
}

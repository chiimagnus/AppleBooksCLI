import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionMembershipTests")
struct CollectionMembershipTests {
    @Test
    func addAllocatesMemberUsesSortStepAndTouchesParent() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 6)
        let member = try memberRow(fixture.database, assetID: "asset-1")
        #expect(member.localPK == 6)
        #expect(member.entityID == 8)
        #expect(member.opt == 1)
        #expect(member.sortKey == 30_000)
        #expect(member.assetLocalPK == 1)
        #expect(member.collectionLocalPK == 10)
        #expect(member.assetID == "asset-1")
        #expect(member.temporaryAssetID == nil)
        #expect(member.localModification > 0)
        let parent = try parentState(fixture.database)
        #expect(parent.opt == 4)
        #expect(parent.lastModification == parent.localModification)
        #expect(parent.lastModification > 1)
    }

    @Test
    func duplicateAddIsIdempotentWithoutPKOrParentTouch() throws {
        let fixture = try fixture(existingTargetMemberships: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed == false)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 1)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 2)
        #expect(try parentState(fixture.database).opt == 3)
    }

    @Test
    func removeDeletesAllDuplicatesAndTouchesParentOnlyWhenChanged() throws {
        let fixture = try fixture(existingTargetMemberships: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 0)
        #expect(try parentState(fixture.database).opt == 4)

        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed == false)
        #expect(try parentState(fixture.database).opt == 4)
    }

    @Test
    func nullAssetIDFailsAddButRemoveIsNoOp() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: CollectionWriteError.bookAssetIDUnavailable) {
            _ = try fixture.writer.addBook(bookLocalPK: 2, toCollectionLocalPK: 10)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)

        #expect(try fixture.writer.removeBook(bookLocalPK: 2, fromCollectionLocalPK: 10).changed == false)
        #expect(try parentState(fixture.database).opt == 3)
    }

    @Test
    func missingBookFailsBeforeBackupAndWantToReadAllowsMembership() throws {
        let missing = try fixture()
        defer { try? FileManager.default.removeItem(at: missing.root) }
        #expect(throws: CollectionWriteError.bookMissing) {
            _ = try missing.writer.addBook(bookLocalPK: 999, toCollectionLocalPK: 10)
        }
        #expect(FileManager.default.fileExists(atPath: missing.backupRoot.path) == false)

        let wantToRead = try fixture(collectionID: "Want_To_Read_Collection_ID")
        defer { try? FileManager.default.removeItem(at: wantToRead.root) }
        #expect(try wantToRead.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed)
    }

    @Test
    func damagedExistingMemberEntityFailsClosed() throws {
        let fixture = try fixture(existingTargetMemberships: 1, targetMemberEntityID: 999)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10)
            Issue.record("expected mutation failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle != nil)
        }
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 1)
        #expect(try parentState(fixture.database).opt == 3)
    }

    private func fixture(
        existingTargetMemberships: Int = 0,
        targetMemberEntityID: Int64 = 8,
        collectionID: String = "550E8400-E29B-41D4-A716-446655440000"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
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
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,10),('BKCollectionMember',8,2)")
        try execute(database, "INSERT INTO ZBKCOLLECTION VALUES(10,7,3,0,0,0,20000,6,NULL,1,1,'\(collectionID)','keep','Shelf')")
        try execute(database, "INSERT INTO ZBKLIBRARYASSET VALUES(1,'asset-1'),(2,NULL),(3,'asset-3')")
        try execute(database, "INSERT INTO ZBKCOLLECTIONMEMBER VALUES(5,8,1,20000,3,10,1,'asset-3',NULL)")
        if existingTargetMemberships >= 1 {
            try execute(database, "INSERT INTO ZBKCOLLECTIONMEMBER VALUES(6,\(targetMemberEntityID),1,30000,1,10,1,'asset-1',NULL)")
        }
        if existingTargetMemberships >= 2 {
            try execute(database, "INSERT INTO ZBKCOLLECTIONMEMBER VALUES(7,\(targetMemberEntityID),1,40000,1,10,1,'asset-1',NULL)")
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

    private func memberRow(_ database: URL, assetID: String) throws -> MemberRow {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        let statement = try connection.prepare("""
            SELECT Z_PK,Z_ENT,Z_OPT,ZSORTKEY,ZASSET,ZCOLLECTION,ZLOCALMODDATE,ZASSETID,ZTEMPORARYASSETID
            FROM ZBKCOLLECTIONMEMBER WHERE ZASSETID=? ORDER BY Z_PK DESC LIMIT 1
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { throw CollectionWriteError.writeFailed }
        let row = try SQLiteRow(statement: statement)
        return MemberRow(
            localPK: try row.int64("Z_PK")!,
            entityID: try row.int64("Z_ENT")!,
            opt: try row.int64("Z_OPT")!,
            sortKey: try row.int64("ZSORTKEY")!,
            assetLocalPK: try row.int64("ZASSET")!,
            collectionLocalPK: try row.int64("ZCOLLECTION")!,
            localModification: try row.double("ZLOCALMODDATE")!,
            assetID: try row.text("ZASSETID"),
            temporaryAssetID: try row.text("ZTEMPORARYASSETID")
        )
    }

    private func parentState(_ database: URL) throws -> ParentState {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        let statement = try connection.prepare("SELECT Z_OPT,ZLASTMODIFICATION,ZLOCALMODDATE FROM ZBKCOLLECTION WHERE Z_PK=10")
        guard try statement.step() else { throw CollectionWriteError.collectionMissing }
        let row = try SQLiteRow(statement: statement)
        return ParentState(
            opt: try row.int64("Z_OPT")!,
            lastModification: try row.double("ZLASTMODIFICATION")!,
            localModification: try row.double("ZLOCALMODDATE")!
        )
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let writer: CollectionWriter
    }

    private struct MemberRow {
        let localPK: Int64
        let entityID: Int64
        let opt: Int64
        let sortKey: Int64
        let assetLocalPK: Int64
        let collectionLocalPK: Int64
        let localModification: Double
        let assetID: String?
        let temporaryAssetID: String?
    }

    private struct ParentState {
        let opt: Int64
        let lastModification: Double
        let localModification: Double
    }
}

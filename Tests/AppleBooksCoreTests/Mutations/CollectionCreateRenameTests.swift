import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionCreateRenameTests")
struct CollectionCreateRenameTests {
    @Test
    func createUsesDynamicPKDefaultsSortUUIDAndExactDetails() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = fixture.writer

        let created = try writer.createCollection(title: "  New Shelf  ", details: "  keep details  ")
        let pk = try #require(created.localPK)
        #expect(pk == 11)
        #expect(created.committed)
        #expect(created.changed)
        #expect(created.warnings.isEmpty)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 11)
        let row = try collectionRow(fixture.database, pk: pk)
        #expect(row.entityID == 7)
        #expect(row.opt == 1)
        #expect(row.deleted == 0)
        #expect(row.hidden == 0)
        #expect(row.placeholder == 0)
        #expect(row.sortKey == 30_000)
        #expect(row.sortMode == 6)
        #expect(row.viewMode == nil)
        #expect(row.title == "New Shelf")
        #expect(row.details == "  keep details  ")
        #expect(row.lastModification == row.localModification)
        #expect(row.lastModification > 0)
        #expect(row.collectionID.flatMap(UUID.init(uuidString:)) != nil)
        #expect(row.collectionID == row.collectionID?.uppercased())
        #expect(created.stableID == row.collectionID)
        #expect(try completedBackups(fixture.backupRoot).count == 1)
    }

    @Test
    func createProjectsExactCommittedIdentitySortAndTimestamp() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var projected: CollectionCloudProjectionInput?
        let writer = CollectionWriter(
            database: fixture.database,
            backupRoot: fixture.backupRoot,
            booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}),
            cloudProjector: CollectionCloudProjector { projected = $0 }
        )

        let result = try writer.createCollection(title: "  Cloud Shelf  ")
        let pk = try #require(result.localPK)
        let row = try collectionRow(fixture.database, pk: pk)
        let projection = try #require(projected)

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        #expect(projection.collectionID == row.collectionID)
        #expect(projection.title == row.title)
        #expect(projection.sortOrder == row.sortKey)
        #expect(projection.modificationDateReferenceSeconds == row.lastModification)
    }

    @Test
    func requestedCloudSyncRequiresProjectionAndPreservesCommittedResultAsWarningOnFailure() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try fixture.writer.createCollection(title: "Sync Shelf", syncCloud: true)

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.warnings == [.cloudSyncFailed])
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Sync Shelf'") == 1)
    }

    @Test
    func requestedCloudSyncRunsAfterSuccessfulProjection() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var projectedID: String?
        var syncedID: String?
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}),
            stateAction: { collectionID in
                syncedID = collectionID
                return .init(editGeneration: 1, syncGeneration: 1, systemFieldsBytes: 1)
            },
            recycleAction: {}
        )
        let writer = CollectionWriter(
            database: fixture.database,
            backupRoot: fixture.backupRoot,
            booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}),
            cloudProjector: CollectionCloudProjector { projectedID = $0.collectionID },
            cloudSynchronizer: synchronizer
        )

        let result = try writer.createCollection(title: "Synced Shelf", syncCloud: true)

        #expect(result.warnings.isEmpty)
        #expect(projectedID == result.stableID)
        #expect(syncedID == result.stableID)
    }

    @Test
    func projectionFailureAlsoMarksRequestedCloudSyncUnconfirmed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writer = CollectionWriter(
            database: fixture.database,
            backupRoot: fixture.backupRoot,
            booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}),
            cloudProjector: CollectionCloudProjector { _ in throw CollectionCloudSyncError.cloudRecordMissing },
            cloudSynchronizer: CollectionCloudSynchronizer(
                booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: {}),
                stateAction: { _ in .init(editGeneration: 1, syncGeneration: 1, systemFieldsBytes: 1) },
                recycleAction: {}
            )
        )

        let result = try writer.createCollection(title: "Projection Failed", syncCloud: true)

        #expect(result.committed)
        #expect(result.warnings == [.cloudProjectionFailed, .cloudSyncFailed])
    }

    @Test
    func renamePreservesIdentityDetailsAndSortWhileTouchingOptAndTimestamps() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try collectionRow(fixture.database, pk: 10)

        _ = try fixture.writer.renameCollection(localPK: 10, newTitle: "  Renamed  ")

        let after = try collectionRow(fixture.database, pk: 10)
        #expect(after.title == "Renamed")
        #expect(after.collectionID == before.collectionID)
        #expect(after.details == before.details)
        #expect(after.sortKey == before.sortKey)
        #expect(after.opt == before.opt + 1)
        #expect(after.lastModification == after.localModification)
        #expect(after.lastModification > before.lastModification)
    }

    @Test
    func emptyTitlesFailBeforeBackupAndSystemRenameFailsInPreflight() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: CollectionWriteError.invalidTitle) {
            _ = try fixture.writer.createCollection(title: " \n ")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)

        try execute(fixture.database, "UPDATE ZBKCOLLECTION SET ZCOLLECTIONID='Books_Collection_ID' WHERE Z_PK=10")
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            try fixture.writer.renameCollection(localPK: 10, newTitle: "Nope")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
    }

    @Test
    func failedInsertRollsBackDomainRowAndPrimaryKeyAdvance() throws {
        let fixture = try fixture(uniqueTitles: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try fixture.writer.createCollection(title: "Old")
            Issue.record("expected transaction failure")
        } catch let failure as MutationFailure {
            #expect(failure.committed == false)
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle != nil)
            #expect(failure.warnings.isEmpty)
        }
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 5)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTION") == 1)
        #expect(try completedBackups(fixture.backupRoot).count == 1)
    }

    private func fixture(uniqueTitles: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let titleConstraint = uniqueTitles ? " UNIQUE" : ""
        try execute(database, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(database, """
            CREATE TABLE ZBKCOLLECTION(
              Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZDELETEDFLAG INTEGER,ZHIDDEN INTEGER,
              ZPLACEHOLDER INTEGER,ZSORTKEY INTEGER,ZSORTMODE INTEGER,ZVIEWMODE INTEGER,ZLASTMODIFICATION REAL,
              ZLOCALMODDATE REAL,ZCOLLECTIONID TEXT,ZDETAILS TEXT,ZTITLE TEXT\(titleConstraint)
            )
            """)
        try execute(database, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,5)")
        try execute(database, """
            INSERT INTO ZBKCOLLECTION VALUES(
              10,7,3,0,0,0,20000,6,NULL,1,1,'550E8400-E29B-41D4-A716-446655440000','keep','Old'
            )
            """)
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
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
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

    private func collectionRow(_ database: URL, pk: Int64) throws -> CollectionRow {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        let statement = try connection.prepare("""
            SELECT Z_ENT,Z_OPT,ZDELETEDFLAG,ZHIDDEN,ZPLACEHOLDER,ZSORTKEY,ZSORTMODE,ZVIEWMODE,
                   ZLASTMODIFICATION,ZLOCALMODDATE,ZCOLLECTIONID,ZDETAILS,ZTITLE
            FROM ZBKCOLLECTION WHERE Z_PK=?
            """)
        try statement.bind(pk, at: 1)
        guard try statement.step() else { throw CollectionWriteError.collectionMissing }
        let row = try SQLiteRow(statement: statement)
        return CollectionRow(
            entityID: try row.int64("Z_ENT")!,
            opt: try row.int64("Z_OPT")!,
            deleted: try row.int64("ZDELETEDFLAG")!,
            hidden: try row.int64("ZHIDDEN")!,
            placeholder: try row.int64("ZPLACEHOLDER")!,
            sortKey: try row.int64("ZSORTKEY")!,
            sortMode: try row.int64("ZSORTMODE")!,
            viewMode: try row.int64("ZVIEWMODE"),
            lastModification: try row.double("ZLASTMODIFICATION")!,
            localModification: try row.double("ZLOCALMODDATE")!,
            collectionID: try row.text("ZCOLLECTIONID"),
            details: try row.text("ZDETAILS"),
            title: try row.text("ZTITLE")
        )
    }

    private func completedBackups(_ root: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { BackupMetadata.parse(filename: $0.lastPathComponent, sourceStem: "library") != nil }
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let writer: CollectionWriter
    }

    private struct CollectionRow {
        let entityID: Int64
        let opt: Int64
        let deleted: Int64
        let hidden: Int64
        let placeholder: Int64
        let sortKey: Int64
        let sortMode: Int64
        let viewMode: Int64?
        let lastModification: Double
        let localModification: Double
        let collectionID: String?
        let details: String?
        let title: String?
    }
}

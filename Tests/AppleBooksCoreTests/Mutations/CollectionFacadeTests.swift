import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionFacadeTests")
struct CollectionFacadeTests {
    @Test
    func facadeRoutesFiveCollectionMutationsThroughSingleWriter() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try core(fixture: fixture, booksRunning: false)

        let created = try books.createCollection(title: "  New Shelf  ", details: "details")
        #expect(created.title == "New Shelf")
        #expect(created.details == "details")

        let renamed = try books.renameCollection(localPK: created.localPK, newTitle: "Renamed")
        #expect(renamed.localPK == created.localPK)
        #expect(renamed.title == "Renamed")

        #expect(try books.addBook(bookLocalPK: 1, toCollectionLocalPK: created.localPK))
        #expect(try books.addBook(bookLocalPK: 1, toCollectionLocalPK: created.localPK) == false)
        #expect(try books.removeBook(bookLocalPK: 1, fromCollectionLocalPK: created.localPK))
        #expect(try books.removeBook(bookLocalPK: 1, fromCollectionLocalPK: created.localPK) == false)

        try books.deleteCollection(localPK: created.localPK)
        #expect(try books.collection(localPK: created.localPK) == nil)
    }

    @Test
    func injectedScratchWriterCannotBypassBooksRunningGateThroughFacade() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try core(fixture: fixture, booksRunning: true)

        #expect(throws: MutationCoordinatorError.booksRunning) {
            _ = try books.createCollection(title: "Blocked")
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
    }

    @Test
    func committedCreateReadBackFailurePropagatesCommittedBoundary() throws {
        let fixture = try fixture(markNewCollectionsDeleted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try core(fixture: fixture, booksRunning: false)

        do {
            _ = try books.createCollection(title: "Committed But Hidden")
            Issue.record("expected committed verification error")
        } catch let error as MutationCommittedVerificationError {
            #expect(error.committed)
            #expect(error.localPK == 11)
            #expect(error.code == "read_back_failed")
            #expect(BackupMetadata.parse(filename: error.backupFilename, sourceStem: "library") != nil)
        }
        #expect(try integer(fixture.library, "SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Committed But Hidden' AND ZDELETEDFLAG=1") == 1)
    }

    private func core(fixture: Fixture, booksRunning: Bool) throws -> AppleBooks {
        try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            historicalConfig: fixture.config,
            collectionWriter: CollectionWriter(
                database: fixture.library,
                backupRoot: fixture.backupRoot,
                booksIsRunning: { booksRunning }
            )
        )
    }

    private func fixture(markNewCollectionsDeleted: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("library.sqlite")
        try execute(library, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(library, """
            CREATE TABLE ZBKCOLLECTION(
              Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZDELETEDFLAG INTEGER,ZHIDDEN INTEGER,
              ZPLACEHOLDER INTEGER,ZSORTKEY INTEGER,ZSORTMODE INTEGER,ZVIEWMODE INTEGER,ZLASTMODIFICATION REAL,
              ZLOCALMODDATE REAL,ZCOLLECTIONID TEXT,ZDETAILS TEXT,ZTITLE TEXT
            )
            """)
        try execute(library, "CREATE TABLE ZBKCOLLECTIONMEMBER(Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZSORTKEY INTEGER,ZASSET INTEGER,ZCOLLECTION INTEGER,ZLOCALMODDATE REAL,ZASSETID TEXT,ZTEMPORARYASSETID TEXT)")
        try execute(library, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT)")
        try execute(library, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,10),('BKCollectionMember',8,0)")
        try execute(library, "INSERT INTO ZBKCOLLECTION VALUES(10,7,1,0,0,0,10000,6,NULL,1,1,'550E8400-E29B-41D4-A716-446655440000',NULL,'Existing')")
        try execute(library, "INSERT INTO ZBKLIBRARYASSET VALUES(1,'asset-1','Book')")
        if markNewCollectionsDeleted {
            try execute(library, """
                CREATE TRIGGER hide_new_collection AFTER INSERT ON ZBKCOLLECTION
                BEGIN
                  UPDATE ZBKCOLLECTION SET ZDELETEDFLAG=1 WHERE Z_PK=NEW.Z_PK;
                END
                """)
        }

        let annotations = root.appendingPathComponent("annotations.sqlite")
        try execute(annotations, "CREATE TABLE placeholder(value INTEGER)")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return Fixture(
            root: root,
            library: library,
            annotations: annotations,
            config: config,
            backupRoot: root.appendingPathComponent("backups")
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

    private struct Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
        let backupRoot: URL
    }
}

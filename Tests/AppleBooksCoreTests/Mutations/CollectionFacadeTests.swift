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
        let books = try core(fixture: fixture, booksApp: closedBooksApp())

        let created = try books.createCollection(title: "  New Shelf  ", details: "details")
        let createdPK = try #require(created.localPK)
        #expect(created.committed)
        #expect(created.changed)
        #expect(created.warnings.isEmpty)
        let readBackCollection = try books.collection(localPK: createdPK)
        let createdCollection = try #require(readBackCollection)
        #expect(createdCollection.title == "New Shelf")
        #expect(createdCollection.details == "details")
        #expect(created.stableID == createdCollection.collectionID)

        let renamed = try books.renameCollection(localPK: createdPK, newTitle: "Renamed")
        #expect(renamed.localPK == createdPK)
        #expect(renamed.changed)
        #expect(try books.collection(localPK: createdPK)?.title == "Renamed")

        #expect(try books.addBook(bookLocalPK: 1, toCollectionLocalPK: createdPK).changed)
        #expect(try books.addBook(bookLocalPK: 1, toCollectionLocalPK: createdPK).changed == false)
        #expect(try books.removeBook(bookLocalPK: 1, fromCollectionLocalPK: createdPK).changed)
        #expect(try books.removeBook(bookLocalPK: 1, fromCollectionLocalPK: createdPK).changed == false)

        #expect(try books.deleteCollection(localPK: createdPK).changed)
        #expect(try books.collection(localPK: createdPK) == nil)
    }

    @Test
    func runningBooksIsQuitForMutationAndRestoredAfterward() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let state = BooksAppState(running: true)
        let books = try core(fixture: fixture, booksApp: state.controller())

        let result = try books.createCollection(title: "Lifecycle")

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        #expect(state.running)
        #expect(state.events.contains("terminate"))
        #expect(state.events.last == "launch")
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path))
    }

    @Test
    func committedCreateReadBackFailurePropagatesCommittedBoundary() throws {
        let fixture = try fixture(markNewCollectionsDeleted: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try core(fixture: fixture, booksApp: closedBooksApp())

        let result = try books.createCollection(title: "Committed But Hidden")
        #expect(result.committed)
        #expect(result.localPK == 11)
        #expect(result.warnings == [.readBackFailed])
        #expect(BackupMetadata.parse(filename: result.backupHandle, sourceStem: "library") != nil)
        #expect(try integer(fixture.library, "SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Committed But Hidden' AND ZDELETEDFLAG=1") == 1)
    }

    private func core(fixture: Fixture, booksApp: BooksAppController) throws -> AppleBooks {
        try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            historicalConfig: fixture.config,
            collectionWriter: CollectionWriter(
                database: fixture.library,
                backupRoot: fixture.backupRoot,
                booksApp: booksApp
            )
        )
    }

    private func closedBooksApp() -> BooksAppController {
        BooksAppController(isRunning: { false }, terminate: { true }, launch: {})
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

    private final class BooksAppState {
        var running: Bool
        var events: [String] = []

        init(running: Bool) {
            self.running = running
        }

        func controller() -> BooksAppController {
            BooksAppController(
                isRunning: { [self] in
                    events.append("isRunning")
                    return running
                },
                terminate: { [self] in
                    events.append("terminate")
                    running = false
                    return true
                },
                launch: { [self] in
                    events.append("launch")
                    running = true
                }
            )
        }
    }
}

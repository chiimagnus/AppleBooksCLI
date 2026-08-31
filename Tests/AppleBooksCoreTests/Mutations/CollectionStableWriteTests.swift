import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionStableWriteTests")
struct CollectionStableWriteTests {
    @Test
    func stableAddRemoveAndDeleteKeepP3MutationContract() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let collectionID = "550E8400-E29B-41D4-A716-446655440000"

        let added = try fixture.writer.addBook(assetID: "asset-1", toCollectionID: collectionID)
        #expect(added.changed)
        #expect(added.localPK == 10)
        #expect(added.stableID == collectionID)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 7)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 30_000)

        let duplicate = try fixture.writer.addBook(assetID: "asset-1", toCollectionID: collectionID)
        #expect(duplicate.changed == false)
        #expect(duplicate.stableID == collectionID)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 7)

        let removed = try fixture.writer.removeBook(assetID: "asset-1", fromCollectionID: collectionID)
        #expect(removed.changed)
        #expect(removed.stableID == collectionID)
        let missingRemove = try fixture.writer.removeBook(assetID: "asset-1", fromCollectionID: collectionID)
        #expect(missingRemove.changed == false)

        let otherID = "550E8400-E29B-41D4-A716-446655440001"
        let deleted = try fixture.writer.deleteCollection(collectionID: otherID)
        #expect(deleted.changed)
        #expect(deleted.localPK == 20)
        #expect(deleted.stableID == otherID)
        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=20") == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 0)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET") == 3)
    }

    @Test
    func stableSelectorsAreExactAndNeverGuessNumericLocalPK() throws {
        let collectionMiss = try makeFixture()
        defer { collectionMiss.remove() }
        #expect(throws: CollectionWriteError.collectionMissing) {
            _ = try collectionMiss.writer.addBook(assetID: "asset-1", toCollectionID: "10")
        }
        #expect(FileManager.default.fileExists(atPath: collectionMiss.backupRoot.path) == false)

        let bookMiss = try makeFixture()
        defer { bookMiss.remove() }
        #expect(throws: CollectionWriteError.bookMissing) {
            _ = try bookMiss.writer.addBook(
                assetID: "1",
                toCollectionID: "550E8400-E29B-41D4-A716-446655440000"
            )
        }
        #expect(FileManager.default.fileExists(atPath: bookMiss.backupRoot.path) == false)
    }

    @Test
    func duplicateStableIdentityFailsClosedBeforeBackup() throws {
        let duplicateCollection = try makeFixture()
        defer { duplicateCollection.remove() }
        try execute(duplicateCollection.database, """
            INSERT INTO ZBKCOLLECTION VALUES(
              50,7,1,0,0,0,50000,6,NULL,1,1,
              '550E8400-E29B-41D4-A716-446655440000',NULL,'Duplicate'
            )
            """)
        #expect(throws: StableIdentityError.ambiguousCollectionID) {
            _ = try duplicateCollection.writer.deleteCollection(
                collectionID: "550E8400-E29B-41D4-A716-446655440000"
            )
        }
        #expect(FileManager.default.fileExists(atPath: duplicateCollection.backupRoot.path) == false)

        let duplicateBook = try makeFixture()
        defer { duplicateBook.remove() }
        try execute(duplicateBook.database, "INSERT INTO ZBKLIBRARYASSET VALUES(4,'asset-1')")
        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try duplicateBook.writer.addBook(
                assetID: "asset-1",
                toCollectionID: "550E8400-E29B-41D4-A716-446655440000"
            )
        }
        #expect(FileManager.default.fileExists(atPath: duplicateBook.backupRoot.path) == false)
    }

    @Test
    func stableSelectorsCannotBypassSystemCollectionGuard() throws {
        let want = try makeFixture()
        defer { want.remove() }
        let wantResult = try want.writer.addBook(assetID: "asset-1", toCollectionID: "Want_To_Read_Collection_ID")
        #expect(wantResult.changed)
        #expect(wantResult.localPK == 30)
        #expect(wantResult.stableID == "Want_To_Read_Collection_ID")

        let wantDelete = try makeFixture()
        defer { wantDelete.remove() }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try wantDelete.writer.deleteCollection(collectionID: "Want_To_Read_Collection_ID")
        }
        #expect(FileManager.default.fileExists(atPath: wantDelete.backupRoot.path) == false)

        let builtIn = try makeFixture()
        defer { builtIn.remove() }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try builtIn.writer.addBook(assetID: "asset-1", toCollectionID: "Books_Collection_ID")
        }
        #expect(FileManager.default.fileExists(atPath: builtIn.backupRoot.path) == false)
    }

    @Test
    func facadeExposesOnlyThePlannedStableWriteOverloads() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let annotations = fixture.root.appendingPathComponent("annotations.sqlite")
        try execute(annotations, "CREATE TABLE placeholder(value INTEGER)")
        let config = fixture.root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let books = try AppleBooks(
            libraryDB: fixture.database,
            annotationsDB: annotations,
            configurationFile: config,
            collectionWriter: fixture.writer
        )
        let collectionID = "550E8400-E29B-41D4-A716-446655440000"

        let added = try books.addBook(assetID: "asset-1", toCollectionID: collectionID)
        #expect(added.changed)
        let removed = try books.removeBook(assetID: "asset-1", fromCollectionID: collectionID)
        #expect(removed.changed)
        let deleted = try books.deleteCollection(collectionID: collectionID)
        #expect(deleted.stableID == collectionID)
        #expect(try books.collection(collectionID: collectionID) == nil)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let sql = try String(contentsOf: fixtureSQL(), encoding: .utf8)
        try execute(database, sql)
        let backupRoot = root.appendingPathComponent("backups")
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            writer: CollectionWriter(database: database, backupRoot: backupRoot, booksApp: closedController())
        )
    }

    private func fixtureSQL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CollectionWriteParity/library.sql")
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

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let writer: CollectionWriter

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

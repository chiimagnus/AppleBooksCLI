import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionWriteParityRegressionTests")
struct CollectionWriteParityRegressionTests {
    @Test
    func createAndRenamePreserveCoreDataInvariants() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let created = try fixture.writer.createCollection(title: "  New Shelf  ", details: "  details stay  ")
        #expect(created.localPK == 41)
        #expect(created.committed)
        #expect(created.changed)
        #expect(created.warnings.isEmpty)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 41)
        #expect(try integer(fixture.database, "SELECT Z_ENT FROM ZBKCOLLECTION WHERE Z_PK=41") == 7)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=41") == 1)
        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=41") == 0)
        #expect(try integer(fixture.database, "SELECT ZHIDDEN FROM ZBKCOLLECTION WHERE Z_PK=41") == 0)
        #expect(try integer(fixture.database, "SELECT ZPLACEHOLDER FROM ZBKCOLLECTION WHERE Z_PK=41") == 0)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=41") == 50_000)
        #expect(try integer(fixture.database, "SELECT ZSORTMODE FROM ZBKCOLLECTION WHERE Z_PK=41") == 6)
        #expect(try isNull(fixture.database, "SELECT ZVIEWMODE FROM ZBKCOLLECTION WHERE Z_PK=41"))
        #expect(try text(fixture.database, "SELECT ZDETAILS FROM ZBKCOLLECTION WHERE Z_PK=41") == "  details stay  ")
        let collectionID = try #require(try text(fixture.database, "SELECT ZCOLLECTIONID FROM ZBKCOLLECTION WHERE Z_PK=41"))
        #expect(UUID(uuidString: collectionID) != nil)
        #expect(collectionID == collectionID.uppercased())
        #expect(created.stableID == collectionID)
        let createTimes = try doubles(fixture.database, "SELECT ZLASTMODIFICATION,ZLOCALMODDATE FROM ZBKCOLLECTION WHERE Z_PK=41")
        #expect(createTimes.0 == createTimes.1)
        #expect(createTimes.0 > 1)

        let originalID = try text(fixture.database, "SELECT ZCOLLECTIONID FROM ZBKCOLLECTION WHERE Z_PK=10")
        let originalDetails = try text(fixture.database, "SELECT ZDETAILS FROM ZBKCOLLECTION WHERE Z_PK=10")
        let originalSort = try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=10")
        let renamed = try fixture.writer.renameCollection(localPK: 10, newTitle: "  Renamed  ")
        #expect(renamed.localPK == 10)
        #expect(renamed.changed)
        #expect(try text(fixture.database, "SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=10") == "Renamed")
        #expect(try text(fixture.database, "SELECT ZCOLLECTIONID FROM ZBKCOLLECTION WHERE Z_PK=10") == originalID)
        #expect(try text(fixture.database, "SELECT ZDETAILS FROM ZBKCOLLECTION WHERE Z_PK=10") == originalDetails)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=10") == originalSort)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 4)
    }

    @Test
    func deleteUsesTombstoneAndCleansOnlyTargetMembership() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bookCount = try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET")

        _ = try fixture.writer.deleteCollection(localPK: 10)

        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=10") == 1)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 4)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10") == 0)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET") == bookCount)
    }

    @Test
    func membershipIsIdempotentAndUsesDynamicMemberPK() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 7)
        #expect(try integer(fixture.database, "SELECT Z_PK FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 7)
        #expect(try integer(fixture.database, "SELECT Z_ENT FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 8)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 1)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 30_000)
        #expect(try integer(fixture.database, "SELECT ZASSET FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 1)
        #expect(try isNull(fixture.database, "SELECT ZTEMPORARYASSETID FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7"))
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 4)

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed == false)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 7)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 4)

        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed)
        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed == false)
        #expect(try integer(fixture.database, "SELECT Z_OPT FROM ZBKCOLLECTION WHERE Z_PK=10") == 5)

        #expect(throws: CollectionWriteError.bookAssetIDUnavailable) {
            _ = try fixture.writer.addBook(bookLocalPK: 2, toCollectionLocalPK: 10)
        }
        #expect(try fixture.writer.removeBook(bookLocalPK: 2, fromCollectionLocalPK: 10).changed == false)
    }

    @Test
    func wantToReadIsMembershipOnlyAndOtherSystemTargetsFailClosed() throws {
        let want = try makeFixture()
        defer { want.remove() }
        #expect(try want.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 30).changed)

        let system = try makeFixture()
        defer { system.remove() }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try system.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 40)
        }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try system.writer.renameCollection(localPK: 40, newTitle: "No")
        }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try system.writer.deleteCollection(localPK: 40)
        }
        #expect(FileManager.default.fileExists(atPath: system.backupRoot.path) == false)
    }

    @Test
    func failedCreateRollsBackPrimaryKeyAndDomainRow() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try execute(fixture.database, "CREATE UNIQUE INDEX unique_collection_title ON ZBKCOLLECTION(ZTITLE)")

        do {
            _ = try fixture.writer.createCollection(title: "Shelf")
            Issue.record("expected mutation failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle != nil)
        }
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 20)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTION") == 4)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let sql = try String(contentsOf: fixtureSQL(), encoding: .utf8)
        try execute(database, sql)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
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

    private func fixtureSQL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CollectionWriteParity/library.sql")
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

    private func text(_ database: URL, _ sql: String) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return nil }
        guard sqlite3_column_type(statement.handle, 0) == SQLITE_TEXT,
              let raw = sqlite3_column_text(statement.handle, 0) else { return nil }
        return String(cString: raw)
    }

    private func isNull(_ database: URL, _ sql: String) throws -> Bool {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return false }
        return sqlite3_column_type(statement.handle, 0) == SQLITE_NULL
    }

    private func doubles(_ database: URL, _ sql: String) throws -> (Double, Double) {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return (0, 0) }
        return (sqlite3_column_double(statement.handle, 0), sqlite3_column_double(statement.handle, 1))
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

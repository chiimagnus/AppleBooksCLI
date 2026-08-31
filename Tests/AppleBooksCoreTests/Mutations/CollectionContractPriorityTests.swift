import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionContractPriorityTests")
struct CollectionContractPriorityTests {
    @Test
    func preservesStableSortIdentityAndIdempotentMembershipContract() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let created = try fixture.writer.createCollection(title: "Priority")
        #expect(created.localPK == 41)
        #expect(try integer(fixture.database, "SELECT Z_ENT FROM ZBKCOLLECTION WHERE Z_PK=41") == 7)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=41") == 50_000)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 41)

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed)
        #expect(try integer(fixture.database, "SELECT Z_PK FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 7)
        #expect(try integer(fixture.database, "SELECT Z_ENT FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 8)
        #expect(try integer(fixture.database, "SELECT ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE Z_PK=7") == 30_000)
        #expect(try integer(fixture.database, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollectionMember'") == 7)

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 10).changed == false)
        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed)
        #expect(try fixture.writer.removeBook(bookLocalPK: 1, fromCollectionLocalPK: 10).changed == false)

        #expect(try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 30).changed)
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try fixture.writer.addBook(bookLocalPK: 1, toCollectionLocalPK: 40)
        }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try fixture.writer.renameCollection(localPK: 30, newTitle: "No")
        }
    }

    @Test
    func deleteTombstonesAndCleansMembershipWithoutDeletingBooks() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bookCount = try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET")

        _ = try fixture.writer.deleteCollection(localPK: 10)

        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=10") == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10") == 0)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKLIBRARYASSET") == bookCount)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let sql = try String(contentsOf: fixtureSQL(), encoding: .utf8)
        try execute(database, sql)
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        return Fixture(
            root: root,
            database: database,
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

    private struct Fixture {
        let root: URL
        let database: URL
        let writer: CollectionWriter

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

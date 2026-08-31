import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionLifecycleRegressionTests")
struct CollectionLifecycleRegressionTests {
    @Test
    func runningBooksLifecycleCoversLocalAndStableCollectionWrites() throws {
        let fixture = try makeFixture(running: true)
        defer { fixture.remove() }

        let created = try fixture.writer.createCollection(title: "Lifecycle")
        let localPK = try #require(created.localPK)
        let collectionID = try #require(created.stableID)
        _ = try fixture.writer.renameCollection(localPK: localPK, newTitle: "Lifecycle Renamed")
        _ = try fixture.writer.addBook(assetID: "asset-1", toCollectionID: collectionID)
        _ = try fixture.writer.removeBook(assetID: "asset-1", fromCollectionID: collectionID)
        _ = try fixture.writer.deleteCollection(collectionID: collectionID)

        #expect(fixture.state.running)
        #expect(fixture.state.terminateCount == 5)
        #expect(fixture.state.launchCount == 5)
        #expect(try integer(fixture.database, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=\(localPK)") == 1)
    }

    @Test
    func originallyClosedWritesNeverLaunchBooks() throws {
        let fixture = try makeFixture(running: false)
        defer { fixture.remove() }

        let created = try fixture.writer.createCollection(title: "Closed")
        let collectionID = try #require(created.stableID)
        _ = try fixture.writer.addBook(assetID: "asset-1", toCollectionID: collectionID)

        #expect(fixture.state.running == false)
        #expect(fixture.state.terminateCount == 0)
        #expect(fixture.state.launchCount == 0)
    }

    @Test
    func stablePreflightAmbiguityDoesNotTouchLifecycleOrBackup() throws {
        let fixture = try makeFixture(running: true)
        defer { fixture.remove() }
        try execute(fixture.database, """
            INSERT INTO ZBKCOLLECTION VALUES(
              50,7,1,0,0,0,50000,6,NULL,1,1,
              '550E8400-E29B-41D4-A716-446655440000',NULL,'Duplicate'
            )
            """)

        #expect(throws: StableIdentityError.ambiguousCollectionID) {
            _ = try fixture.writer.deleteCollection(
                collectionID: "550E8400-E29B-41D4-A716-446655440000"
            )
        }
        #expect(fixture.state.running)
        #expect(fixture.state.terminateCount == 0)
        #expect(fixture.state.launchCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
    }

    @Test
    func stableMutationFailureRestoresOriginalRunningState() throws {
        let fixture = try makeFixture(running: true)
        defer { fixture.remove() }
        try execute(fixture.database, """
            CREATE TRIGGER block_member_insert
            BEFORE INSERT ON ZBKCOLLECTIONMEMBER
            BEGIN SELECT RAISE(ABORT,'blocked'); END
            """)

        do {
            _ = try fixture.writer.addBook(
                assetID: "asset-1",
                toCollectionID: "550E8400-E29B-41D4-A716-446655440000"
            )
            Issue.record("expected stable mutation failure")
        } catch let error as MutationFailure {
            #expect(error.code == .mutationFailed)
            #expect(error.backupHandle != nil)
        }
        #expect(fixture.state.running)
        #expect(fixture.state.terminateCount == 1)
        #expect(fixture.state.launchCount == 1)
        #expect(try integer(fixture.database, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'") == 0)
    }

    private func makeFixture(running: Bool) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        let sql = try String(contentsOf: fixtureSQL(), encoding: .utf8)
        try execute(database, sql)
        let backupRoot = root.appendingPathComponent("backups")
        let state = LifecycleState(running: running)
        let controller = BooksAppController(
            isRunning: { state.running },
            terminate: {
                state.terminateCount += 1
                state.running = false
                return true
            },
            launch: {
                state.launchCount += 1
                state.running = true
            },
            sleep: { _ in }
        )
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            state: state,
            writer: CollectionWriter(database: database, backupRoot: backupRoot, booksApp: controller)
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

    private final class LifecycleState {
        var running: Bool
        var terminateCount = 0
        var launchCount = 0

        init(running: Bool) {
            self.running = running
        }
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let state: LifecycleState
        let writer: CollectionWriter

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

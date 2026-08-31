import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CoreDataPrimaryKeyTests")
struct CoreDataPrimaryKeyTests {
    @Test
    func requiresCallerOwnedTransaction() throws {
        let fixture = try fixture(zMax: 5, tablePKs: [10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: CoreDataPrimaryKeyError.transactionRequired) {
            _ = try CoreDataPrimaryKey.allocate(entityName: "BKCollection", table: .collections, on: fixture.handle)
        }
    }

    @Test
    func allocatesAboveStaleZMaxAndTableMax() throws {
        let fixture = try fixture(zMax: 5, tablePKs: [3, 10])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute(fixture.handle, "BEGIN IMMEDIATE")
        let allocation = try CoreDataPrimaryKey.allocate(
            entityName: "BKCollection",
            table: .collections,
            on: fixture.handle
        )
        #expect(allocation == .init(entityID: 7, localPK: 11))
        #expect(try scalar(fixture.handle, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 11)
        try execute(fixture.handle, "ROLLBACK")
        #expect(try scalar(fixture.handle, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME='BKCollection'") == 5)
    }

    @Test
    func missingDuplicateAndInvalidEntityFailClosed() throws {
        let fixture = try fixture(zMax: 5, tablePKs: [])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try execute(fixture.handle, "BEGIN IMMEDIATE")
        #expect(throws: CoreDataPrimaryKeyError.missingEntity) {
            _ = try CoreDataPrimaryKey.allocate(entityName: "Missing", table: .collections, on: fixture.handle)
        }
        try execute(fixture.handle, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,5)")
        #expect(throws: CoreDataPrimaryKeyError.duplicateEntity) {
            _ = try CoreDataPrimaryKey.allocate(entityName: "BKCollection", table: .collections, on: fixture.handle)
        }
        try execute(fixture.handle, "DELETE FROM Z_PRIMARYKEY; INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',NULL,-1)")
        #expect(throws: CoreDataPrimaryKeyError.invalidEntity) {
            _ = try CoreDataPrimaryKey.allocate(entityName: "BKCollection", table: .collections, on: fixture.handle)
        }
        try execute(fixture.handle, "ROLLBACK")
    }

    private func fixture(zMax: Int64, tablePKs: [Int64]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("library.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        try execute(handle, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER)")
        try execute(handle, "CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER,Z_ENT INTEGER)")
        try execute(handle, "CREATE TABLE ZBKCOLLECTIONMEMBER(Z_PK INTEGER,Z_ENT INTEGER)")
        try execute(handle, "INSERT INTO Z_PRIMARYKEY VALUES('BKCollection',7,\(zMax))")
        for pk in tablePKs {
            try execute(handle, "INSERT INTO ZBKCOLLECTION VALUES(\(pk),7)")
        }
        return Fixture(root: root, handle: handle)
    }

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }

    private func scalar(_ handle: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private final class Fixture {
        let root: URL
        let handle: OpaquePointer

        init(root: URL, handle: OpaquePointer) {
            self.root = root
            self.handle = handle
        }

        deinit { sqlite3_close_v2(handle) }
    }
}

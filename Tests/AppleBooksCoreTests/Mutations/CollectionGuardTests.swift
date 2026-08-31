import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionGuardTests")
struct CollectionGuardTests {
    @Test
    func userUUIDCollectionIsEditableForCollectionAndMembershipMutations() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try insert(fixture.handle, pk: 1, id: "550E8400-E29B-41D4-A716-446655440000", deleted: 0)

        #expect(try CollectionWriter.editableTarget(localPK: 1, scope: .collection, on: fixture.handle) == .init(localPK: 1, stableID: nil))
        #expect(try CollectionWriter.editableTarget(localPK: 1, scope: .membership, on: fixture.handle) == .init(localPK: 1, stableID: nil))
    }

    @Test
    func wantToReadIsMembershipOnlyAndOtherSentinelsFailClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try insert(fixture.handle, pk: 1, id: "Want_To_Read_Collection_ID", deleted: 0)
        try insert(fixture.handle, pk: 2, id: "Books_Collection_ID", deleted: 0)
        try insert(fixture.handle, pk: 3, id: "Future_System_Collection_ID", deleted: 0)

        #expect(try CollectionWriter.editableTarget(localPK: 1, scope: .membership, on: fixture.handle) == .init(localPK: 1, stableID: nil))
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try CollectionWriter.editableTarget(localPK: 1, scope: .collection, on: fixture.handle)
        }
        for pk in [Int64(2), 3] {
            #expect(throws: CollectionWriteError.collectionNotEditable) {
                _ = try CollectionWriter.editableTarget(localPK: pk, scope: .membership, on: fixture.handle)
            }
        }
    }

    @Test
    func deletedNullAndUnknownDeletedStateFailClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let uuid = "550E8400-E29B-41D4-A716-446655440000"
        try insert(fixture.handle, pk: 1, id: uuid, deleted: 1)
        try insert(fixture.handle, pk: 2, id: uuid, deleted: 2)
        try insert(fixture.handle, pk: 3, id: uuid, deleted: nil)

        for pk in [Int64(1), 2, 3] {
            #expect(throws: CollectionWriteError.collectionDeletedOrUnknown) {
                _ = try CollectionWriter.editableTarget(localPK: pk, scope: .collection, on: fixture.handle)
            }
        }
    }

    @Test
    func missingNullAndUnrecognizedIdentityFailClosed() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try insert(fixture.handle, pk: 1, id: nil, deleted: 0)
        try insert(fixture.handle, pk: 2, id: "not-a-uuid", deleted: 0)

        #expect(throws: CollectionWriteError.collectionMissing) {
            _ = try CollectionWriter.editableTarget(localPK: 99, scope: .collection, on: fixture.handle)
        }
        #expect(throws: CollectionWriteError.collectionIdentityUnavailable) {
            _ = try CollectionWriter.editableTarget(localPK: 1, scope: .collection, on: fixture.handle)
        }
        #expect(throws: CollectionWriteError.collectionNotEditable) {
            _ = try CollectionWriter.editableTarget(localPK: 2, scope: .collection, on: fixture.handle)
        }
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        guard sqlite3_exec(
            handle,
            "CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY,ZCOLLECTIONID TEXT,ZTITLE TEXT,ZDELETEDFLAG INTEGER)",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        return Fixture(root: root, handle: handle)
    }

    private func insert(_ handle: OpaquePointer, pk: Int64, id: String?, deleted: Int64?) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ZBKCOLLECTION VALUES(?,?,NULL,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, pk)
        if let id {
            _ = id.withCString { sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        } else {
            sqlite3_bind_null(statement, 2)
        }
        if let deleted {
            sqlite3_bind_int64(statement, 3, deleted)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
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

import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("WriteSchemaGuardTests")
struct WriteSchemaGuardTests {
    @Test
    func fixedWriterMatricesMatchPlannedColumns() {
        #expect(WriteSchemaGuard.collectionKnownColumns == [
            "Z_PK", "Z_ENT", "Z_OPT", "ZDELETEDFLAG", "ZHIDDEN", "ZPLACEHOLDER",
            "ZSORTKEY", "ZSORTMODE", "ZVIEWMODE", "ZLASTMODIFICATION", "ZLOCALMODDATE",
            "ZCOLLECTIONID", "ZDETAILS", "ZTITLE",
        ])
        #expect(WriteSchemaGuard.memberKnownColumns == [
            "Z_PK", "Z_ENT", "Z_OPT", "ZSORTKEY", "ZASSET", "ZCOLLECTION",
            "ZLOCALMODDATE", "ZASSETID", "ZTEMPORARYASSETID",
        ])
    }

    @Test
    func insertRejectsUnknownNotNullButUpdateDoesNot() throws {
        let db = try database(collectionExtra: "ZNEWREQUIRED TEXT NOT NULL DEFAULT ''")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: db.path)

        #expect(throws: WriteSchemaGuardError.unknownRequiredColumns(
            table: "ZBKCOLLECTION",
            columns: ["ZNEWREQUIRED"]
        )) {
            try WriteSchemaGuard.validateTable(
                .collections,
                required: WriteSchemaGuard.collectionKnownColumns,
                inserting: true,
                on: connection
            )
        }
        try WriteSchemaGuard.validateTable(
            .collections,
            required: ["Z_PK", "ZTITLE"],
            inserting: false,
            on: connection
        )
    }

    @Test
    func nullableUnknownColumnDoesNotBlockInsert() throws {
        let db = try database(collectionExtra: "ZNEWOPTIONAL TEXT")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: db.path)

        try WriteSchemaGuard.validateTable(
            .collections,
            required: WriteSchemaGuard.collectionKnownColumns,
            inserting: true,
            on: connection
        )
    }

    @Test
    func memberInsertRejectsUnknownNotNullWhileBookLookupIgnoresIt() throws {
        let db = try database(collectionExtra: "", memberExtra: "ZNEWREQUIRED TEXT NOT NULL DEFAULT ''")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: db.path)

        #expect(throws: WriteSchemaGuardError.unknownRequiredColumns(
            table: "ZBKCOLLECTIONMEMBER",
            columns: ["ZNEWREQUIRED"]
        )) {
            try WriteSchemaGuard.validateTable(
                .members,
                required: WriteSchemaGuard.memberKnownColumns,
                inserting: true,
                on: connection
            )
        }
        try WriteSchemaGuard.validateTable(
            .books,
            required: ["Z_PK", "ZASSETID"],
            inserting: false,
            on: connection
        )
    }

    @Test
    func entityMetadataRequiresExactlyOneValidPrimaryKeyRow() throws {
        let db = try database(collectionExtra: "")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(db.path, &handle) == SQLITE_OK)
        let writable = try #require(handle)
        defer { sqlite3_close_v2(writable) }

        try execute(writable, "INSERT INTO Z_PRIMARYKEY(Z_NAME,Z_ENT,Z_MAX) VALUES('BKCollection', 7, 41)")
        let connection = try SQLiteConnection.readOnly(path: db.path)
        #expect(try WriteSchemaGuard.entity(named: "BKCollection", on: connection) == .init(entityID: 7, maxPK: 41))

        try execute(writable, "INSERT INTO Z_PRIMARYKEY(Z_NAME,Z_ENT,Z_MAX) VALUES('BKCollection', 7, 42)")
        #expect(throws: WriteSchemaGuardError.duplicateEntity("BKCollection")) {
            _ = try WriteSchemaGuard.entity(named: "BKCollection", on: connection)
        }
        #expect(throws: WriteSchemaGuardError.missingEntity("BKCollectionMember")) {
            _ = try WriteSchemaGuard.entity(named: "BKCollectionMember", on: connection)
        }
    }

    @Test
    func entityMetadataRejectsNullOrInvalidValues() throws {
        let db = try database(collectionExtra: "")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(db.path, &handle) == SQLITE_OK)
        let writable = try #require(handle)
        defer { sqlite3_close_v2(writable) }
        try execute(writable, "INSERT INTO Z_PRIMARYKEY(Z_NAME,Z_ENT,Z_MAX) VALUES('BKCollection', NULL, 1)")
        try execute(writable, "INSERT INTO Z_PRIMARYKEY(Z_NAME,Z_ENT,Z_MAX) VALUES('BKCollectionMember', 8, -1)")

        let connection = try SQLiteConnection.readOnly(path: db.path)
        #expect(throws: WriteSchemaGuardError.invalidEntity("BKCollection")) {
            _ = try WriteSchemaGuard.entity(named: "BKCollection", on: connection)
        }
        #expect(throws: WriteSchemaGuardError.invalidEntity("BKCollectionMember")) {
            _ = try WriteSchemaGuard.entity(named: "BKCollectionMember", on: connection)
        }
    }

    @Test
    func targetEntityMustMatchResolvedEntity() throws {
        let db = try database(collectionExtra: "")
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(db.path, &handle) == SQLITE_OK)
        let writable = try #require(handle)
        defer { sqlite3_close_v2(writable) }
        try execute(writable, "INSERT INTO ZBKCOLLECTION(Z_PK,Z_ENT) VALUES(1,7)")

        let connection = try SQLiteConnection.readOnly(path: db.path)
        try WriteSchemaGuard.validateExistingEntity(
            table: .collections,
            localPK: 1,
            expectedEntityID: 7,
            on: connection
        )
        #expect(throws: WriteSchemaGuardError.entityMismatch("ZBKCOLLECTION")) {
            try WriteSchemaGuard.validateExistingEntity(
                table: .collections,
                localPK: 1,
                expectedEntityID: 8,
                on: connection
            )
        }
    }

    private func database(collectionExtra: String, memberExtra: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("BKLibrary.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw SQLiteBackupError.destinationOpenFailed
        }
        defer { sqlite3_close_v2(handle) }

        let collectionColumns = [
            "Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER", "ZDELETEDFLAG INTEGER",
            "ZHIDDEN INTEGER", "ZPLACEHOLDER INTEGER", "ZSORTKEY INTEGER", "ZSORTMODE INTEGER",
            "ZVIEWMODE INTEGER", "ZLASTMODIFICATION REAL", "ZLOCALMODDATE REAL", "ZCOLLECTIONID TEXT",
            "ZDETAILS TEXT", "ZTITLE TEXT", collectionExtra,
        ].filter { $0.isEmpty == false }.joined(separator: ",")
        try execute(handle, "CREATE TABLE ZBKCOLLECTION(\(collectionColumns))")
        let memberColumns = [
            "Z_PK INTEGER PRIMARY KEY", "Z_ENT INTEGER", "Z_OPT INTEGER", "ZSORTKEY INTEGER",
            "ZASSET INTEGER", "ZCOLLECTION INTEGER", "ZLOCALMODDATE REAL", "ZASSETID TEXT",
            "ZTEMPORARYASSETID TEXT", memberExtra,
        ].filter { $0.isEmpty == false }.joined(separator: ",")
        try execute(handle, "CREATE TABLE ZBKCOLLECTIONMEMBER(\(memberColumns))")
        try execute(handle, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZUNRELATED TEXT NOT NULL)")
        try execute(handle, "CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER,ZUNRELATED TEXT NOT NULL DEFAULT '')")
        return url
    }

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }
}

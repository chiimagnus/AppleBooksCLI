import AppleBooksCloudBridge
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionCloudProjectorTests")
struct CollectionCloudProjectorTests {
    @Test
    func liveProjectorUsesCanonicalLibraryAndBacksUpOncePerBatch() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.libraryDirectory, withIntermediateDirectories: true)
        let library = paths.libraryDirectory.appendingPathComponent("BKLibrary-test.sqlite")
        try execute(library, "CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY,ZCOLLECTIONID TEXT); INSERT INTO ZBKCOLLECTION VALUES(7,'COLLECTION-ID')")

        var events: [String] = []
        let projector = try #require(CollectionCloudProjector.live(
            libraryDatabase: library,
            homeDirectory: root,
            backupRoot: root.appendingPathComponent("backups", isDirectory: true),
            backupAction: { source, backupRoot in
                events.append("backup")
                #expect(source.path.hasSuffix("BCCloudCollections/BCCloudCollections"))
                #expect(backupRoot.lastPathComponent == "backups")
            },
            bridgeAction: { cloudRoot, database, passedLibrary, input in
                events.append("bridge")
                #expect(passedLibrary == library)
                #expect(cloudRoot.lastPathComponent == "BCCloudData-BookDataStoreService")
                #expect(database.path.hasSuffix("BCCloudCollections/BCCloudCollections"))
                #expect(input == .collection(localPK: 7))
                return 0
            }
        ))

        try projector.project([.collection(localPK: 7), .collection(localPK: 7)])
        #expect(events == ["backup", "bridge", "bridge"])
    }

    @Test
    func collectionIdentityPreservesEmbeddedNULFromDatabase() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        try execute(library, "CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY,ZCOLLECTIONID TEXT)")
        try insertCollection(library, collectionID: "collection\0tail")

        #expect(try CollectionCloudProjector.collectionID(libraryDatabase: library, localPK: 7) == "collection\0tail")
    }

    @Test
    func bridgeUsesExactLengthForCollectionIdentityLookup() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCCloudCollections", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let cloudDatabase = storeDirectory.appendingPathComponent("BCCloudCollections")
        try Data().write(to: cloudDatabase)
        let library = root.appendingPathComponent("library.sqlite")
        try execute(library, """
            CREATE TABLE ZBKCOLLECTION(
              Z_PK INTEGER PRIMARY KEY,
              ZCOLLECTIONID TEXT,
              ZDELETEDFLAG INTEGER,
              ZHIDDEN INTEGER,
              ZSORTMODE INTEGER,
              ZSORTKEY INTEGER,
              ZLASTMODIFICATION REAL,
              ZTITLE TEXT,
              ZDETAILS TEXT
            )
            """)
        try insertBridgeCollection(library, collectionID: "collection\0tail")

        let status = root.path.withCString { rootPath in
            cloudDatabase.path.withCString { cloudPath in
                library.path.withCString { libraryPath in
                    withCloudBridgeUTF8Bytes("collection\0tail") { collectionID, collectionIDLength in
                        ABProjectCollectionState(
                            rootPath,
                            cloudPath,
                            libraryPath,
                            collectionID,
                            collectionIDLength
                        )
                    }
                }
            }
        }
        #expect(status >= 4)
    }

    @Test
    func nonCanonicalLibraryDisablesLiveProjection() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("fixture.sqlite")
        try Data().write(to: outside)
        #expect(CollectionCloudProjector.live(libraryDatabase: outside, homeDirectory: root) == nil)
    }

    @Test
    func bridgeFailureIsStructuredAfterBackup() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.libraryDirectory, withIntermediateDirectories: true)
        let library = paths.libraryDirectory.appendingPathComponent("BKLibrary-test.sqlite")
        try execute(library, "CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY,ZCOLLECTIONID TEXT); INSERT INTO ZBKCOLLECTION VALUES(7,'COLLECTION-ID')")

        var backupCount = 0
        let projector = try #require(CollectionCloudProjector.live(
            libraryDatabase: library,
            homeDirectory: root,
            backupAction: { _, _ in backupCount += 1 },
            bridgeAction: { _, _, _, _ in 14 }
        ))
        #expect(throws: CollectionCloudProjectionError.bridgeRejected(14)) {
            try projector.project(.collection(localPK: 7))
        }
        #expect(backupCount == 1)
    }

    @Test
    func bridgeRejectsWrongCollectionStoreLayoutBeforePrivateFrameworkAccess() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCCloudCollections", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let database = storeDirectory.appendingPathComponent("BCCloudCollections")
        let library = root.appendingPathComponent("library.sqlite")
        try Data().write(to: database)
        try Data().write(to: library)

        let status = storeDirectory.path.withCString { rootPath in
            database.path.withCString { databasePath in
                library.path.withCString { libraryPath in
                    withCloudBridgeUTF8Bytes("\0COLLECTION") { collectionID, collectionIDLength in
                        ABProjectCollectionState(
                            rootPath,
                            databasePath,
                            libraryPath,
                            collectionID,
                            collectionIDLength
                        )
                    }
                }
            }
        }
        #expect(status == 2)

        let invalidBytes: [UInt8] = [0xFF]
        let invalidStatus = storeDirectory.path.withCString { rootPath in
            database.path.withCString { databasePath in
                library.path.withCString { libraryPath in
                    invalidBytes.withUnsafeBufferPointer { invalid in
                        ABProjectCollectionState(
                            rootPath,
                            databasePath,
                            libraryPath,
                            invalid.baseAddress!,
                            invalid.count
                        )
                    }
                }
            }
        }
        #expect(invalidStatus == 1)
    }

    private func insertCollection(_ database: URL, collectionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ZBKCOLLECTION(Z_PK,ZCOLLECTIONID) VALUES(7,?)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle) }
        defer { sqlite3_finalize(statement) }
        try bindExact(collectionID, to: statement, index: 1, handle: handle)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func insertBridgeCollection(_ database: URL, collectionID: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ZBKCOLLECTION VALUES(7,?,0,0,6,20000,1,'Synthetic',NULL)", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SQLiteError.current(operation: .prepare, code: sqlite3_errcode(handle), handle: handle) }
        defer { sqlite3_finalize(statement) }
        try bindExact(collectionID, to: statement, index: 1, handle: handle)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func bindExact(_ value: String, to statement: OpaquePointer, index: Int32, handle: OpaquePointer) throws {
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes { raw in
            sqlite3_bind_text64(
                statement,
                index,
                raw.baseAddress,
                sqlite3_uint64(raw.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self),
                UInt8(SQLITE_UTF8)
            )
        }
        guard result == SQLITE_OK else { throw SQLiteError.current(operation: .bind, code: result, handle: handle) }
    }

    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func execute(_ database: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw SQLiteBackupError.destinationOpenFailed }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }
}

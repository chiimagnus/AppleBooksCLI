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
                    "00000000-0000-0000-0000-000000000001".withCString { collectionID in
                        ABProjectCollectionState(rootPath, databasePath, libraryPath, collectionID)
                    }
                }
            }
        }
        #expect(status == 2)
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

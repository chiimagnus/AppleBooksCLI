import AppleBooksCloudBridge
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationCloudProjectorTests")
struct AnnotationCloudProjectorTests {
    @Test
    func liveProjectorResolvesExactAssetAndUUIDAfterBackup() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.annotationsDirectory, withIntermediateDirectories: true)
        let annotations = paths.annotationsDirectory.appendingPathComponent("AEAnnotation-test.sqlite")
        try execute(annotations, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT); INSERT INTO ZAEANNOTATION VALUES(7,'ASSET','UUID')")

        var events: [String] = []
        let projector = try #require(AnnotationCloudProjector.live(
            annotationsDatabase: annotations,
            homeDirectory: root,
            backupRoot: root.appendingPathComponent("backups", isDirectory: true),
            backupAction: { source, backupRoot in
                events.append("backup")
                #expect(source.path.hasSuffix("BCAssetData/BCAssetData"))
                #expect(backupRoot.lastPathComponent == "backups")
            },
            bridgeAction: { cloudRoot, database, passedAnnotations, identity in
                events.append("bridge")
                #expect(passedAnnotations == annotations)
                #expect(cloudRoot.path.hasSuffix("BCCloudData-iBooks"))
                #expect(database.path.hasSuffix("BCAssetData/BCAssetData"))
                #expect(identity == .init(assetID: "ASSET", uuid: "UUID"))
                return 0
            }
        ))

        try projector.project(localPK: 7)
        #expect(events == ["backup", "bridge"])
    }

    @Test
    func nonCanonicalAnnotationsDatabaseDisablesLiveProjection() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("fixture.sqlite")
        try Data().write(to: outside)
        #expect(AnnotationCloudProjector.live(annotationsDatabase: outside, homeDirectory: root) == nil)
    }

    @Test
    func identityRequiresUniqueNonEmptyAssetAndUUID() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("annotations.sqlite")
        try execute(database, "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER,ZANNOTATIONASSETID TEXT,ZANNOTATIONUUID TEXT); INSERT INTO ZAEANNOTATION VALUES(1,'ASSET','UUID'),(1,'OTHER','OTHER')")
        #expect(throws: AnnotationCloudProjectionError.identityUnavailable) {
            _ = try AnnotationCloudProjector.identity(annotationsDatabase: database, localPK: 1)
        }
    }

    @Test
    func bridgeRejectsWrongAnnotationStoreLayoutBeforePrivateFrameworkAccess() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCAssetData", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let database = storeDirectory.appendingPathComponent("BCAssetData")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try Data().write(to: database)
        try Data().write(to: annotations)
        let status = storeDirectory.path.withCString { rootPath in
            database.path.withCString { databasePath in
                annotations.path.withCString { annotationsPath in
                    "ASSET".withCString { assetID in
                        "UUID".withCString { uuid in
                            ABProjectAnnotationState(rootPath, databasePath, annotationsPath, assetID, uuid)
                        }
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

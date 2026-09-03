import AppleBooksCloudBridge
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("CollectionCloudProjectorTests")
struct CollectionCloudProjectorTests {
    @Test
    func liveProjectorRequiresCanonicalDiscoveredLibraryAndBacksUpBeforeBridge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.libraryDirectory, withIntermediateDirectories: true)
        let library = paths.libraryDirectory.appendingPathComponent("BKLibrary-test.sqlite")
        try Data().write(to: library)

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
            bridgeAction: { cloudRoot, database, input in
                events.append("bridge")
                #expect(cloudRoot.lastPathComponent == "BCCloudData-BookDataStoreService")
                #expect(database == cloudRoot
                    .appendingPathComponent("BCCloudCollections", isDirectory: true)
                    .appendingPathComponent("BCCloudCollections", isDirectory: false))
                #expect(input.collectionID == "COLLECTION-ID")
                #expect(input.title == "Title")
                #expect(input.sortOrder == 30_000)
                #expect(input.modificationDateReferenceSeconds == 123)
                return 0
            }
        ))

        try projector.project(.init(
            collectionID: "COLLECTION-ID",
            title: "Title",
            sortOrder: 30_000,
            modificationDateReferenceSeconds: 123
        ))
        #expect(events == ["backup", "bridge"])
    }

    @Test
    func nonCanonicalLibraryDisablesLiveProjection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("fixture.sqlite")
        try Data().write(to: outside)

        #expect(CollectionCloudProjector.live(libraryDatabase: outside, homeDirectory: root) == nil)
    }

    @Test
    func bridgeRejectsWrongRootAndDirectoryDatabaseBeforePrivateFrameworkAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeDirectory = root.appendingPathComponent("BCCloudCollections", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let database = storeDirectory.appendingPathComponent("BCCloudCollections", isDirectory: false)
        try Data().write(to: database)

        let wrongRootStatus = bridgeStatus(root: storeDirectory, database: database)
        #expect(wrongRootStatus == 2)

        try FileManager.default.removeItem(at: database)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: false)
        let directoryDatabaseStatus = bridgeStatus(root: root, database: database)
        #expect(directoryDatabaseStatus == 2)
    }

    @Test
    func bridgeFailureIsStructuredAfterBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppleBooksDatabasePaths.defaults(homeDirectory: root)
        try FileManager.default.createDirectory(at: paths.libraryDirectory, withIntermediateDirectories: true)
        let library = paths.libraryDirectory.appendingPathComponent("BKLibrary-test.sqlite")
        try Data().write(to: library)

        var backupCount = 0
        let projector = try #require(CollectionCloudProjector.live(
            libraryDatabase: library,
            homeDirectory: root,
            backupAction: { _, _ in backupCount += 1 },
            bridgeAction: { _, _, _ in 14 }
        ))

        do {
            try projector.project(.init(
                collectionID: "COLLECTION-ID",
                title: "Title",
                sortOrder: 30_000,
                modificationDateReferenceSeconds: 123
            ))
            Issue.record("expected bridge failure")
        } catch let error as CollectionCloudProjectionError {
            #expect(error == .bridgeRejected(14))
        }
        #expect(backupCount == 1)
    }

    private func bridgeStatus(root: URL, database: URL) -> Int32 {
        root.path.withCString { rootPath in
            database.path.withCString { databasePath in
                "00000000-0000-0000-0000-000000000001".withCString { collectionID in
                    "Probe".withCString { title in
                        ABProjectCollectionDetail(rootPath, databasePath, collectionID, title, 10_000, 0)
                    }
                }
            }
        }
    }
}

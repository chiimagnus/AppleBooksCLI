import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationCloudSynchronizerTests")
struct AnnotationCloudSynchronizerTests {
    @Test
    func acknowledgedAssetSkipsBooksLifecycle() throws {
        let events = Events()
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: true),
            stateAction: { _ in .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 10) },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 1
        )
        try synchronizer.sync(
            localPK: 7,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values.isEmpty)
    }

    @Test
    func originallyClosedDirtyAssetLaunchesBooksAndWaitsForAck() throws {
        let events = Events()
        var reads = 0
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: false),
            stateAction: { localPK in
                #expect(localPK == 7)
                defer { reads += 1 }
                return reads < 2
                    ? .init(editGeneration: 2, syncGeneration: 1, systemFieldsBytes: 10)
                    : .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 10)
            },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 3
        )
        try synchronizer.sync(
            localPK: 7,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values == ["launchWithoutActivation", "temporaryLaunch", "sleep"])
        #expect(reads == 3)
    }

    @Test
    func alreadyRunningDirtyAssetOnlyWaitsBecauseCoordinatorOwnsRelaunch() throws {
        let events = Events()
        var reads = 0
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: true),
            stateAction: { _ in
                defer { reads += 1 }
                return reads == 0
                    ? .init(editGeneration: 2, syncGeneration: 1, systemFieldsBytes: 10)
                    : .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 10)
            },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 2
        )
        try synchronizer.sync(
            localPK: 7,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values.isEmpty)
        #expect(reads == 2)
    }

    @Test
    func missingAssetFailsBeforeLaunchingBooks() throws {
        let events = Events()
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: false),
            stateAction: { _ in nil },
            maxPollCount: 1
        )
        #expect(throws: AnnotationCloudSyncError.cloudRecordMissing) {
            try synchronizer.sync(
                localPK: 7,
                onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
            )
        }
        #expect(events.values.isEmpty)
    }

    @Test
    func pendingBatchSeamOnlyWaitsForAcknowledgement() throws {
        let events = Events()
        var reads = 0
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: true),
            stateAction: { _ in nil },
            pendingCount: {
                defer { reads += 1 }
                return reads < 2 ? 2 : 0
            },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 3
        )

        #expect(try synchronizer.pendingCount() == 2)
        try synchronizer.waitForPendingAcknowledgement()

        #expect(events.values == ["sleep"])
        #expect(reads == 3)
    }

    @Test
    func liveStateAndPendingCountFailClosedOnMalformedCloudStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("cloud.sqlite")
        try executeSQL(
            """
            CREATE TABLE ZBCASSETANNOTATIONS(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZEDITGENERATION,
              ZSYNCGENERATION,
              ZCKSYSTEMFIELDS
            );
            INSERT INTO ZBCASSETANNOTATIONS VALUES(1, 'ASSET', 2, 2, X'01');
            """,
            at: database
        )

        #expect(try AnnotationCloudSynchronizer.readPendingCount(database: database) == 0)
        #expect(try AnnotationCloudSynchronizer.readState(database: database, assetID: "ASSET")?.isAcknowledged == true)

        try executeSQL("UPDATE ZBCASSETANNOTATIONS SET ZCKSYSTEMFIELDS=NULL", at: database)
        #expect(try AnnotationCloudSynchronizer.readPendingCount(database: database) == 1)
        #expect(try AnnotationCloudSynchronizer.readState(database: database, assetID: "ASSET")?.systemFieldsBytes == 0)

        try executeSQL("UPDATE ZBCASSETANNOTATIONS SET ZCKSYSTEMFIELDS=X''", at: database)
        #expect(try AnnotationCloudSynchronizer.readPendingCount(database: database) == 1)

        for malformed in ["123", "'fields'"] {
            try executeSQL("UPDATE ZBCASSETANNOTATIONS SET ZCKSYSTEMFIELDS=\(malformed)", at: database)
            #expect(throws: AnnotationCloudSyncError.cloudRecordInvalid) {
                _ = try AnnotationCloudSynchronizer.readPendingCount(database: database)
            }
            #expect(throws: AnnotationCloudSyncError.cloudRecordInvalid) {
                _ = try AnnotationCloudSynchronizer.readState(database: database, assetID: "ASSET")
            }
        }

        try executeSQL("UPDATE ZBCASSETANNOTATIONS SET ZCKSYSTEMFIELDS=X'01', ZEDITGENERATION='bad'", at: database)
        #expect(throws: AnnotationCloudSyncError.cloudRecordInvalid) {
            _ = try AnnotationCloudSynchronizer.readPendingCount(database: database)
        }
        #expect(throws: AnnotationCloudSyncError.cloudRecordInvalid) {
            _ = try AnnotationCloudSynchronizer.readState(database: database, assetID: "ASSET")
        }
    }

    @Test
    func dirtyAssetTimesOutWithoutPretendingAck() throws {
        let events = Events()
        let synchronizer = AnnotationCloudSynchronizer(
            booksApp: controller(events: events, running: false),
            stateAction: { _ in .init(editGeneration: 2, syncGeneration: 1, systemFieldsBytes: 10) },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 2
        )
        #expect(throws: AnnotationCloudSyncError.acknowledgementTimedOut) {
            try synchronizer.sync(
                localPK: 7,
                onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
            )
        }
        #expect(events.values == ["launchWithoutActivation", "temporaryLaunch", "sleep", "sleep"])
    }

    private func executeSQL(_ sql: String, at database: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw AnnotationCloudSyncError.cloudRecordInvalid
        }
    }

    private func controller(events: Events, running initial: Bool) -> BooksAppController {
        var running = initial
        return BooksAppController(
            isRunning: { running },
            terminate: { events.values.append("terminate"); running = false; return true },
            launch: { events.values.append("launch"); running = true },
            launchWithoutActivation: { events.values.append("launchWithoutActivation"); running = true },
            sleep: { _ in }
        )
    }

    private final class Events {
        var values: [String] = []
    }
}

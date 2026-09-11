import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionCloudSynchronizerTests")
struct CollectionCloudSynchronizerTests {
    @Test
    func acknowledgedCollectionSkipsLifecycle() throws {
        let events = Events()
        let acked = state(edit: 2, sync: 2)
        let synchronizer = makeSynchronizer(events: events, detail: { _ in acked })
        try synchronizer.syncCollection(
            localPK: 7,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values.isEmpty)
    }

    @Test
    func runningSingleRecordRecyclesWithoutTakingBooksLifecycleOwnership() throws {
        let events = Events()
        let dirty = state(edit: 2, sync: 1)
        let acked = state(edit: 2, sync: 2)
        var reads = 0
        let synchronizer = makeSynchronizer(
            events: events,
            runningInitially: true,
            detail: { localPK in
                #expect(localPK == 7)
                defer { reads += 1 }
                return reads < 2 ? dirty : acked
            },
            maxPollCount: 3
        )
        try synchronizer.syncCollection(
            localPK: 7,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values == ["recycle", "sleep"])
        #expect(reads == 3)
    }

    @Test
    func membershipRequiresParentAndMemberAck() throws {
        let events = Events()
        let acked = state(edit: 2, sync: 2)
        let dirty = state(edit: 2, sync: 1)
        var memberReads = 0
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in acked },
            member: { localPK, assetID in
                #expect(localPK == 7)
                #expect(assetID == "ASSET")
                defer { memberReads += 1 }
                return memberReads == 0 ? dirty : acked
            },
            maxPollCount: 2
        )
        try synchronizer.syncMembership(
            collectionLocalPK: 7,
            assetID: "ASSET",
            deleting: false,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values == ["recycle", "launchWithoutActivation", "temporaryLaunch"])
        #expect(memberReads == 2)
    }

    @Test
    func collectionDeleteAcceptsPhysicalRemovalAndAckedMemberTombstones() throws {
        let events = Events()
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in nil },
            deletedMembersSatisfied: { _ in true }
        )
        try synchronizer.syncCollection(
            localPK: 7,
            deleting: true,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values.isEmpty)
    }

    @Test
    func deletedMemberAggregateHandlesLargeSetsAndLiteralCollectionPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("cloud.sqlite")
        let collectionID = "COLL%_\\"
        try executeSQL(
            """
            CREATE TABLE ZBCCOLLECTIONMEMBER(
              ZCOLLECTIONMEMBERID TEXT,
              ZDELETEDFLAG INTEGER,
              ZEDITGENERATION INTEGER,
              ZSYNCGENERATION INTEGER,
              ZCKSYSTEMFIELDS BLOB
            );
            WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9))
            INSERT INTO ZBCCOLLECTIONMEMBER
            SELECT '\(collectionID)|A' || (a.d + b.d*10 + c.d*100 + d.d*1000), 1, 3, 3, X'01'
            FROM digits a, digits b, digits c, digits d;
            INSERT INTO ZBCCOLLECTIONMEMBER VALUES('COLL-otherX\\|foreign', 0, 9, 0, NULL);
            """,
            at: database
        )

        #expect(try CollectionCloudSynchronizer.readDeletedMembersSatisfied(database: database, collectionID: collectionID))

        try executeSQL(
            "UPDATE ZBCCOLLECTIONMEMBER SET ZSYNCGENERATION=2 WHERE ZCOLLECTIONMEMBERID='\(collectionID)|A9999'",
            at: database
        )
        #expect(try CollectionCloudSynchronizer.readDeletedMembersSatisfied(database: database, collectionID: collectionID) == false)

        try executeSQL(
            "UPDATE ZBCCOLLECTIONMEMBER SET ZSYNCGENERATION=3, ZCKSYSTEMFIELDS=NULL WHERE ZCOLLECTIONMEMBERID='\(collectionID)|A9999'",
            at: database
        )
        #expect(try CollectionCloudSynchronizer.readDeletedMembersSatisfied(database: database, collectionID: collectionID) == false)

        try executeSQL("DELETE FROM ZBCCOLLECTIONMEMBER", at: database)
        #expect(try CollectionCloudSynchronizer.readDeletedMembersSatisfied(database: database, collectionID: collectionID))
    }

    @Test
    func removeMembershipAcceptsPhysicalRemoval() throws {
        let events = Events()
        let acked = state(edit: 2, sync: 2)
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in acked },
            member: { _, _ in nil }
        )
        try synchronizer.syncMembership(
            collectionLocalPK: 7,
            assetID: "ASSET",
            deleting: true,
            onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
        )
        #expect(events.values.isEmpty)
    }

    @Test
    func missingRequiredUpsertRecordFailsBeforeLifecycle() throws {
        let events = Events()
        let synchronizer = makeSynchronizer(events: events, detail: { _ in nil })
        #expect(throws: CollectionCloudSyncError.cloudRecordMissing) {
            try synchronizer.syncCollection(
                localPK: 7,
                onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
            )
        }
        #expect(events.values.isEmpty)
    }

    @Test
    func recycleFailureStopsBeforeLaunch() throws {
        let events = Events()
        let dirty = state(edit: 1, sync: 0, fields: 0)
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(isRunning: { false }, terminate: { true }, launch: { events.values.append("launch") }),
            detailState: { _ in dirty },
            memberState: { _, _ in nil },
            deletedMembersSatisfied: { _ in true },
            recycleAction: { events.values.append("recycle"); throw CollectionCloudSyncError.serviceRecycleFailed },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 1
        )
        #expect(throws: CollectionCloudSyncError.serviceRecycleFailed) {
            try synchronizer.syncCollection(
                localPK: 7,
                onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
            )
        }
        #expect(events.values == ["recycle"])
    }

    @Test
    func pendingBatchSeamOnlyRecyclesAndWaitsForAcknowledgement() throws {
        let events = Events()
        var reads = 0
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in nil },
            pending: {
                defer { reads += 1 }
                return reads < 2 ? 3 : 0
            },
            maxPollCount: 3
        )

        #expect(try synchronizer.pendingCount() == 3)
        try synchronizer.preparePendingBatch()
        try synchronizer.waitForPendingAcknowledgement()

        #expect(events.values == ["recycle", "sleep"])
        #expect(reads == 3)
    }

    @Test
    func dirtyRecordTimesOutWithoutPretendingAck() throws {
        let events = Events()
        let dirty = state(edit: 1, sync: 0, fields: 0)
        let synchronizer = makeSynchronizer(events: events, detail: { _ in dirty }, maxPollCount: 2)
        #expect(throws: CollectionCloudSyncError.acknowledgementTimedOut) {
            try synchronizer.syncCollection(
                localPK: 7,
                onTemporaryBooksLaunch: { events.values.append("temporaryLaunch") }
            )
        }
        #expect(events.values == ["recycle", "launchWithoutActivation", "temporaryLaunch", "sleep", "sleep"])
    }

    private func makeSynchronizer(
        events: Events,
        runningInitially: Bool = false,
        detail: @escaping CollectionCloudSynchronizer.DetailStateAction,
        member: @escaping CollectionCloudSynchronizer.MemberStateAction = { _, _ in nil },
        deletedMembersSatisfied: @escaping CollectionCloudSynchronizer.DeletedMembersSatisfiedAction = { _ in true },
        pending: @escaping CollectionCloudSynchronizer.PendingCountAction = { 0 },
        maxPollCount: Int = 1
    ) -> CollectionCloudSynchronizer {
        var running = runningInitially
        return CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { running },
                terminate: { events.values.append("terminate"); running = false; return true },
                launch: { events.values.append("launch"); running = true },
                launchWithoutActivation: { events.values.append("launchWithoutActivation"); running = true },
                sleep: { _ in }
            ),
            detailState: detail,
            memberState: member,
            deletedMembersSatisfied: deletedMembersSatisfied,
            pendingCount: pending,
            recycleAction: { events.values.append("recycle") },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: maxPollCount
        )
    }

    private func executeSQL(_ sql: String, at database: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw CollectionCloudSyncError.cloudRecordInvalid
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CollectionCloudSyncError.cloudRecordInvalid
        }
    }

    private func state(
        deleted: Bool = false,
        edit: Int64,
        sync: Int64,
        fields: Int64 = 10
    ) -> CollectionCloudSyncState {
        CollectionCloudSyncState(
            deleted: deleted,
            editGeneration: edit,
            syncGeneration: sync,
            systemFieldsBytes: fields
        )
    }

    private final class Events {
        var values: [String] = []
    }
}

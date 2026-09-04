import Foundation
import Testing
@testable import AppleBooksCore

@Suite("CollectionCloudSynchronizerTests")
struct CollectionCloudSynchronizerTests {
    @Test
    func acknowledgedCollectionSkipsLifecycle() throws {
        let events = Events()
        let acked = state(edit: 2, sync: 2)
        let synchronizer = makeSynchronizer(events: events, detail: { _ in acked })
        try synchronizer.syncCollection(localPK: 7)
        #expect(events.values.isEmpty)
    }

    @Test
    func dirtyCollectionRecyclesServiceAndWaitsForAck() throws {
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
        try synchronizer.syncCollection(localPK: 7)
        #expect(events.values == ["terminate", "recycle", "launch", "sleep"])
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
        try synchronizer.syncMembership(collectionLocalPK: 7, assetID: "ASSET", deleting: false)
        #expect(events.values == ["recycle", "launch"])
        #expect(memberReads == 2)
    }

    @Test
    func collectionDeleteAcceptsPhysicalRemovalAndAckedMemberTombstones() throws {
        let events = Events()
        let deletedAck = state(deleted: true, edit: 3, sync: 3)
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in nil },
            deletedMembers: { _ in [deletedAck] }
        )
        try synchronizer.syncCollection(localPK: 7, deleting: true)
        #expect(events.values.isEmpty)
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
        try synchronizer.syncMembership(collectionLocalPK: 7, assetID: "ASSET", deleting: true)
        #expect(events.values.isEmpty)
    }

    @Test
    func missingRequiredUpsertRecordFailsBeforeLifecycle() throws {
        let events = Events()
        let synchronizer = makeSynchronizer(events: events, detail: { _ in nil })
        #expect(throws: CollectionCloudSyncError.cloudRecordMissing) {
            try synchronizer.syncCollection(localPK: 7)
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
            deletedMemberStates: { _ in [] },
            recycleAction: { events.values.append("recycle"); throw CollectionCloudSyncError.serviceRecycleFailed },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: 1
        )
        #expect(throws: CollectionCloudSyncError.serviceRecycleFailed) {
            try synchronizer.syncCollection(localPK: 7)
        }
        #expect(events.values == ["recycle"])
    }

    @Test
    func pendingBatchWithNoChangesSkipsLifecycle() throws {
        let events = Events()
        let synchronizer = makeSynchronizer(
            events: events,
            detail: { _ in nil },
            pending: { 0 }
        )
        #expect(try synchronizer.pendingCount() == 0)
        try synchronizer.syncPending()
        #expect(events.values.isEmpty)
    }

    @Test
    func pendingBatchTriggersOneLifecycleAndWaitsForAllRows() throws {
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
        try synchronizer.syncPending()
        #expect(events.values == ["recycle", "launch", "sleep"])
        #expect(reads == 3)
    }

    @Test
    func dirtyRecordTimesOutWithoutPretendingAck() throws {
        let events = Events()
        let dirty = state(edit: 1, sync: 0, fields: 0)
        let synchronizer = makeSynchronizer(events: events, detail: { _ in dirty }, maxPollCount: 2)
        #expect(throws: CollectionCloudSyncError.acknowledgementTimedOut) {
            try synchronizer.syncCollection(localPK: 7)
        }
        #expect(events.values == ["recycle", "launch", "sleep", "sleep"])
    }

    private func makeSynchronizer(
        events: Events,
        runningInitially: Bool = false,
        detail: @escaping CollectionCloudSynchronizer.DetailStateAction,
        member: @escaping CollectionCloudSynchronizer.MemberStateAction = { _, _ in nil },
        deletedMembers: @escaping CollectionCloudSynchronizer.DeletedMemberStatesAction = { _ in [] },
        pending: @escaping CollectionCloudSynchronizer.PendingCountAction = { 0 },
        maxPollCount: Int = 1
    ) -> CollectionCloudSynchronizer {
        var running = runningInitially
        return CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { running },
                terminate: { events.values.append("terminate"); running = false; return true },
                launch: { events.values.append("launch"); running = true },
                sleep: { _ in }
            ),
            detailState: detail,
            memberState: member,
            deletedMemberStates: deletedMembers,
            pendingCount: pending,
            recycleAction: { events.values.append("recycle") },
            sleep: { _ in events.values.append("sleep") },
            maxPollCount: maxPollCount
        )
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

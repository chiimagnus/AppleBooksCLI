import Foundation
import Testing
@testable import AppleBooksCore

@Suite("CollectionCloudSynchronizerTests")
struct CollectionCloudSynchronizerTests {
    @Test
    func acknowledgedRecordSkipsBooksAndServiceLifecycle() throws {
        var events: [String] = []
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { events.append("isRunning"); return true },
                terminate: { events.append("terminate"); return true },
                launch: { events.append("launch") }
            ),
            stateAction: { _ in .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 10) },
            recycleAction: { events.append("recycle") },
            sleep: { _ in events.append("sleep") },
            maxPollCount: 1
        )

        try synchronizer.sync(collectionID: "COLLECTION-ID")

        #expect(events.isEmpty)
    }

    @Test
    func dirtyRecordRecyclesServiceLaunchesBooksAndWaitsForExactAck() throws {
        var events: [String] = []
        var running = true
        var stateReads = 0
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { running },
                terminate: { events.append("terminate"); running = false; return true },
                launch: { events.append("launch"); running = true },
                sleep: { _ in }
            ),
            stateAction: { collectionID in
                #expect(collectionID == "COLLECTION-ID")
                defer { stateReads += 1 }
                switch stateReads {
                case 0, 1:
                    return .init(editGeneration: 1, syncGeneration: 0, systemFieldsBytes: 0)
                default:
                    return .init(editGeneration: 2, syncGeneration: 2, systemFieldsBytes: 2473)
                }
            },
            recycleAction: { events.append("recycle") },
            sleep: { _ in events.append("sleep") },
            maxPollCount: 3
        )

        try synchronizer.sync(collectionID: "COLLECTION-ID")

        #expect(events == ["terminate", "recycle", "launch", "sleep"])
        #expect(stateReads == 3)
    }

    @Test
    func missingRecordFailsBeforeAnyLifecycleMutation() throws {
        var events: [String] = []
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { events.append("isRunning"); return true },
                terminate: { events.append("terminate"); return true },
                launch: { events.append("launch") }
            ),
            stateAction: { _ in nil },
            recycleAction: { events.append("recycle") },
            sleep: { _ in events.append("sleep") },
            maxPollCount: 1
        )

        #expect(throws: CollectionCloudSyncError.cloudRecordMissing) {
            try synchronizer.sync(collectionID: "COLLECTION-ID")
        }
        #expect(events.isEmpty)
    }

    @Test
    func recycleFailureStopsBeforeLaunchingBooks() throws {
        var events: [String] = []
        let dirty = CollectionCloudSyncState(editGeneration: 1, syncGeneration: 0, systemFieldsBytes: 0)
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { false },
                terminate: { events.append("terminate"); return true },
                launch: { events.append("launch") }
            ),
            stateAction: { _ in dirty },
            recycleAction: {
                events.append("recycle")
                throw CollectionCloudSyncError.serviceRecycleFailed
            },
            sleep: { _ in events.append("sleep") },
            maxPollCount: 1
        )

        #expect(throws: CollectionCloudSyncError.serviceRecycleFailed) {
            try synchronizer.sync(collectionID: "COLLECTION-ID")
        }
        #expect(events == ["recycle"])
    }

    @Test
    func dirtyRecordTimesOutWithoutPretendingAck() throws {
        var events: [String] = []
        let dirty = CollectionCloudSyncState(editGeneration: 1, syncGeneration: 0, systemFieldsBytes: 0)
        let synchronizer = CollectionCloudSynchronizer(
            booksApp: BooksAppController(
                isRunning: { false },
                terminate: { events.append("terminate"); return true },
                launch: { events.append("launch") }
            ),
            stateAction: { _ in dirty },
            recycleAction: { events.append("recycle") },
            sleep: { _ in events.append("sleep") },
            maxPollCount: 2
        )

        #expect(throws: CollectionCloudSyncError.acknowledgementTimedOut) {
            try synchronizer.sync(collectionID: "COLLECTION-ID")
        }
        #expect(events == ["recycle", "launch", "sleep", "sleep"])
    }
}

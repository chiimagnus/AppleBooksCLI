import Foundation
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
        try synchronizer.sync(localPK: 7)
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
        try synchronizer.sync(localPK: 7)
        #expect(events.values == ["launch", "sleep"])
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
        try synchronizer.sync(localPK: 7)
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
            try synchronizer.sync(localPK: 7)
        }
        #expect(events.values.isEmpty)
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
            try synchronizer.sync(localPK: 7)
        }
        #expect(events.values == ["launch", "sleep", "sleep"])
    }

    private func controller(events: Events, running initial: Bool) -> BooksAppController {
        var running = initial
        return BooksAppController(
            isRunning: { running },
            terminate: { events.values.append("terminate"); running = false; return true },
            launch: { events.values.append("launch"); running = true },
            sleep: { _ in }
        )
    }

    private final class Events {
        var values: [String] = []
    }
}

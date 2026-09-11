import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("SyncCommandTests")
struct SyncCommandTests {
    @Test
    func rootHelpRegistersBatchCloudSyncSurface() {
        var stdout = ""
        var stderr = ""
        let code = CLIEntrypoint.run(
            arguments: ["--help"],
            output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(stderr.isEmpty)
        #expect(stdout.contains("sync"))
    }

    @Test
    func noPendingChangesDoNotTouchBooksLifecycle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(state: .frontmost, collectionPending: 0, annotationPending: 0)
        let command = try SyncCommand.parse([])

        let result = try command.execute(using: try fixture.books(harness: harness))

        #expect(result.status == .noPendingChanges)
        #expect(result.acknowledged == nil)
        #expect(result.collectionPendingBefore == 0)
        #expect(result.annotationPendingBefore == 0)
        #expect(result.warningCodes.isEmpty)
        #expect(harness.events.isEmpty)
        #expect(harness.state == .frontmost)
    }

    @Test
    func bothDomainsRestoreOriginallyClosedBooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(state: .closed, collectionPending: 2, annotationPending: 1)
        let command = try SyncCommand.parse([])

        let result = try command.execute(using: try fixture.books(harness: harness))

        #expect(result.status == .acknowledged)
        #expect(result.acknowledged == true)
        #expect(result.collectionPendingBefore == 2)
        #expect(result.annotationPendingBefore == 1)
        #expect(result.warningCodes.isEmpty)
        #expect(harness.events == ["recycle", "launchWithoutActivation", "terminate"])
        #expect(harness.state == .closed)
    }

    @Test
    func collectionOnlySyncRestoresBackgroundBooksWithoutActivation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(state: .background, collectionPending: 1, annotationPending: 0)
        let command = try SyncCommand.parse([])

        let result = try command.execute(using: try fixture.books(harness: harness))

        #expect(result.status == .acknowledged)
        #expect(result.acknowledged == true)
        #expect(harness.events == ["terminate", "recycle", "launchWithoutActivation"])
        #expect(harness.events.contains("activate") == false)
        #expect(harness.state == .background)
    }

    @Test
    func annotationOnlySyncRestoresFrontmostBooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(state: .frontmost, collectionPending: 0, annotationPending: 1)
        let command = try SyncCommand.parse([])

        let result = try command.execute(using: try fixture.books(harness: harness))

        #expect(result.status == .acknowledged)
        #expect(result.acknowledged == true)
        #expect(harness.events == ["terminate", "launchWithoutActivation", "activate"])
        #expect(harness.state == .frontmost)
    }

    @Test
    func acknowledgementFailureRestoresBooksAndExposesSafeRetry() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(
            state: .closed,
            collectionPending: 0,
            annotationPending: 1,
            failAcknowledgement: true
        )
        let command = try SyncCommand.parse([])

        do {
            _ = try command.execute(using: try fixture.books(harness: harness))
            Issue.record("Expected sync acknowledgement failure")
        } catch let error as CLIError {
            #expect(error.code == .unavailable)
            #expect(error.reason == "cloud_sync_failed")
            #expect(error.recoveryHint == "It is safe to rerun `applebookscli sync`.")
            #expect(error.message == "Apple Books cloud sync did not reach acknowledgement.")
        }

        #expect(harness.events == ["launchWithoutActivation", "terminate"])
        #expect(harness.state == .closed)
    }

    @Test
    func acknowledgedSyncKeepsAckFactWhenStateRestoreFails() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(
            state: .closed,
            collectionPending: 0,
            annotationPending: 1,
            failStateRestore: true
        )
        let command = try SyncCommand.parse([])

        let result = try command.execute(using: try fixture.books(harness: harness))

        #expect(result.status == .acknowledged)
        #expect(result.acknowledged == true)
        #expect(result.warningCodes == [MutationWarning.booksStateRestoreFailed.rawValue])
        #expect(harness.state == .background)
    }

    @Test
    func acknowledgementFailureDoesNotHideStateRestoreFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let harness = LifecycleHarness(
            state: .closed,
            collectionPending: 0,
            annotationPending: 1,
            failAcknowledgement: true,
            failStateRestore: true
        )
        let command = try SyncCommand.parse([])

        do {
            _ = try command.execute(using: try fixture.books(harness: harness))
            Issue.record("Expected sync acknowledgement failure")
        } catch let error as CLIError {
            #expect(error.reason == "cloud_sync_failed")
            #expect(error.recoveryHint == "It is safe to rerun `applebookscli sync`.")
            #expect(error.message.contains("original Books app state could not be restored"))
        }
        #expect(harness.state == .background)
    }

    private final class LifecycleHarness {
        var running: Bool
        var frontmost: Bool
        var collectionPending: Int
        var annotationPending: Int
        let failAcknowledgement: Bool
        let failStateRestore: Bool
        var events: [String] = []

        init(
            state: BooksAppState,
            collectionPending: Int,
            annotationPending: Int,
            failAcknowledgement: Bool = false,
            failStateRestore: Bool = false
        ) {
            switch state {
            case .closed:
                running = false
                frontmost = false
            case .background:
                running = true
                frontmost = false
            case .frontmost:
                running = true
                frontmost = true
            }
            self.collectionPending = collectionPending
            self.annotationPending = annotationPending
            self.failAcknowledgement = failAcknowledgement
            self.failStateRestore = failStateRestore
        }

        var state: BooksAppState {
            if running == false { return .closed }
            return frontmost ? .frontmost : .background
        }

        var controller: BooksAppController {
            BooksAppController(
                isRunning: { self.running },
                terminate: {
                    self.events.append("terminate")
                    if self.failStateRestore && self.running && self.events.contains("launchWithoutActivation") {
                        return false
                    }
                    self.running = false
                    self.frontmost = false
                    return true
                },
                launch: {
                    self.events.append("launch")
                    self.running = true
                    self.frontmost = true
                    if self.failAcknowledgement == false { self.annotationPending = 0 }
                },
                isFrontmost: { self.frontmost },
                launchWithoutActivation: {
                    self.events.append("launchWithoutActivation")
                    self.running = true
                    self.frontmost = false
                    if self.failAcknowledgement == false { self.annotationPending = 0 }
                },
                activate: {
                    self.events.append("activate")
                    if self.failStateRestore { throw BooksAppControllerError.launchFailed }
                    self.frontmost = true
                },
                sleep: { _ in }
            )
        }
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(library)
            try Self.createDatabase(annotations)
            try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
        }

        func books(harness: LifecycleHarness) throws -> AppleBooks {
            let controller = harness.controller
            let collectionSynchronizer = CollectionCloudSynchronizer(
                booksApp: controller,
                detailState: { _ in nil },
                memberState: { _, _ in nil },
                deletedMemberStates: { _ in [] },
                pendingCount: { harness.collectionPending },
                recycleAction: {
                    harness.events.append("recycle")
                    harness.collectionPending = 0
                }
            )
            let annotationSynchronizer = AnnotationCloudSynchronizer(
                booksApp: controller,
                stateAction: { _ in nil },
                pendingCount: { harness.annotationPending },
                sleep: { _ in },
                maxPollCount: 1
            )
            return try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(
                    database: library,
                    booksApp: controller,
                    cloudSynchronizer: collectionSynchronizer
                ),
                annotationWriter: AnnotationWriter(
                    database: annotations,
                    booksApp: controller,
                    cloudSynchronizer: annotationSynchronizer
                ),
                syncBooksApp: controller
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func createDatabase(_ url: URL) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            sqlite3_close_v2(handle)
        }
    }

    private enum FixtureError: Error { case sqlite }
}

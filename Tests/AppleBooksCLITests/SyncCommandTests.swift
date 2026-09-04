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
    func commandFlushesBothDomainsThroughOneLifecycle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try SyncCommand.parse([])

        var events: [String] = []
        var running = false
        var collectionPending = 2
        var annotationPending = 1
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { events.append("terminate"); running = false; return true },
            launch: { events.append("launch"); running = true },
            sleep: { _ in }
        )
        let collectionSynchronizer = CollectionCloudSynchronizer(
            booksApp: controller,
            detailState: { _ in nil },
            memberState: { _, _ in nil },
            deletedMemberStates: { _ in [] },
            pendingCount: { collectionPending },
            recycleAction: {
                events.append("recycle")
                collectionPending = 0
                annotationPending = 0
            }
        )
        let annotationSynchronizer = AnnotationCloudSynchronizer(
            booksApp: controller,
            stateAction: { _ in nil },
            pendingCount: { annotationPending }
        )
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config,
            collectionWriter: CollectionWriter(
                database: fixture.library,
                booksApp: controller,
                cloudSynchronizer: collectionSynchronizer
            ),
            annotationWriter: AnnotationWriter(
                database: fixture.annotations,
                booksApp: controller,
                cloudSynchronizer: annotationSynchronizer
            )
        )

        let result = try command.execute(using: books)

        #expect(result.acknowledged)
        #expect(result.collectionPendingBefore == 2)
        #expect(result.annotationPendingBefore == 1)
        #expect(events == ["recycle", "launch"])
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

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func createDatabase(_ url: URL) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            sqlite3_close_v2(handle)
        }
    }

    private enum FixtureError: Error { case sqlite }
}

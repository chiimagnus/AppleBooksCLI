import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("HistoryCommandTests")
struct HistoryCommandTests {
    @Test
    func listIsNewestFirstWithStableTieBreakAndKeepsPrivateDetailOutOfSummary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fixed = fixture.date("2026-09-04T10:00:00Z")
        let olderStore = fixture.store(now: fixed.addingTimeInterval(-60))
        let older = try olderStore.beginTestHistory(operation: "sync")
        try olderStore.completeTestHistory(older, exitCode: 0)

        let store = fixture.store(now: fixed)
        let first = try store.beginTestHistory(operation: "collections.create")
        try store.completeTestHistory(first, exitCode: 0)
        let second = try store.beginTestHistory(operation: "annotations.update-note")
        try store.completeTestHistory(second, exitCode: 1)

        let command = try HistoryListCommand.parse([])
        let capture = Capture()
        try command.run(output: capture.output, store: store)
        let result = try JSONDecoder.history.decode(HistoryListResult.self, from: Data(capture.stdout.utf8))
        #expect(result.items.map(\.id) == [first.id, second.id].sorted() + [older.id])
        #expect(capture.stdout.contains("private title") == false)
        #expect(capture.stdout.contains("private note") == false)
        #expect(capture.stdout.contains("private-error-secret") == false)
        #expect(capture.stderr.isEmpty)
    }

    @Test
    func getDistinguishesCompletedFromIncompleteRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let completed = try store.beginTestHistory(operation: "sync")
        try store.completeTestHistory(completed, exitCode: 0)
        let incomplete = try store.beginTestHistory(operation: "collections.rename")

        let completedResult = try runJSONGet(completed.id, store: store)
        #expect(completedResult.status == .success)
        #expect(completedResult.request == .unavailable)
        #expect(completedResult.result == .unavailable)
        #expect(completedResult.inverse == .unavailable)
        #expect(completedResult.completedAt != nil)
        #expect(completedResult.exitCode == 0)

        let incompleteResult = try runJSONGet(incomplete.id, store: store)
        #expect(incompleteResult.status == .incomplete)
        #expect(incompleteResult.request == .unavailable)
        #expect(incompleteResult.result == nil)
        #expect(incompleteResult.inverse == .unavailable)
        #expect(incompleteResult.completedAt == nil)
        #expect(incompleteResult.exitCode == nil)
    }

    @Test
    func jsonGetEscapesControlCharactersInsteadOfReplayingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let privateTitle = "line1\nline2\u{001B}[31m"
        let token = try store.beginTestHistory(
            operation: "collections.rename",
            request: OperationHistoryRequest(
                selector: OperationHistorySelector(collectionID: "collection-id"),
                title: privateTitle
            )
        )
        try store.complete(
            token,
            exitCode: 0,
            completion: OperationHistoryCompletion(
                result: .unavailable,
                inverse: OperationHistoryInverse(
                    available: true,
                    operation: "collections.rename",
                    selector: OperationHistorySelector(collectionID: "collection-id"),
                    noteAction: nil,
                    title: privateTitle
                )
            )
        )

        let command = try HistoryGetCommand.parse([token.id])
        let capture = Capture()
        try command.run(output: capture.output, store: store)
        #expect(capture.stdout.contains("line1\\nline2"))
        #expect(capture.stdout.contains("\\u001b"))
        #expect(capture.stdout.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(capture.stderr.isEmpty)
    }

    @Test
    func missingRootIsEmptyOrNotFoundWithoutCreatingState() throws {
        let fixture = try Fixture(createRoot: false)
        defer { fixture.remove() }
        let store = fixture.store()
        let list = try HistoryListCommand.parse([])
        let listCapture = Capture()
        try list.run(output: listCapture.output, store: store)
        let result = try JSONDecoder.history.decode(HistoryListResult.self, from: Data(listCapture.stdout.utf8))
        #expect(result.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path) == false)

        let get = try HistoryGetCommand.parse(["00000000-0000-4000-8000-000000000000"])
        #expect(throws: CLIError.notFoundWithReason(
            message: "Operation history entry not found.",
            reason: .historyEntryNotFound
        )) {
            try get.run(output: Capture().output, store: store)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.root.path) == false)
    }

    @Test
    func corruptStoreMapsToStableUnavailableWithoutReflectingPathOrPayload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let privatePayload = "private-history-payload"
        try Data((privatePayload + "\n").utf8).write(to: fixture.root.appendingPathComponent("2026-09-04.jsonl"))
        let command = try HistoryListCommand.parse([])

        do {
            try command.run(output: Capture().output, store: fixture.store(now: fixture.date("2026-09-04T10:00:00Z")))
            Issue.record("expected unavailable")
        } catch let error as CLIError {
            #expect(error == .unavailableWithReason(
                message: "Operation history is unavailable.",
                reason: .historyUnavailable
            ))
            #expect(error.message.contains(privatePayload) == false)
            #expect(error.message.contains(fixture.root.path) == false)
        }
    }

    @Test
    func paginationAndHistoryIDInputsFailBeforeRootIO() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: target)
        let store = fixture.store()

        for arguments in [
            ["--limit", "0"],
            ["--limit", "101"],
            ["--cursor", "!"],
        ] {
            let command = try HistoryListCommand.parse(arguments)
            do {
                try command.run(output: Capture().output, store: store)
                Issue.record("expected usage-invalid pagination input")
            } catch let error as CLIError {
                #expect(error.code == .usageInvalid)
            }
        }

        let invalidGet = try HistoryGetCommand.parse(["00000000-0000-4000-8000-00000000000A"])
        do {
            try invalidGet.run(output: Capture().output, store: store)
            Issue.record("expected usage-invalid history ID")
        } catch let error as CLIError {
            #expect(error.code == .usageInvalid)
        }
        #expect(throws: (any Error).self) {
            _ = try HistoryListCommand.parse(["--offset", "1"])
        }
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test
    func listAndGetDoNotCreateRecursiveHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let token = try store.beginTestHistory(operation: "sync")
        try store.completeTestHistory(token, exitCode: 0)
        let before = try store.listPage(limit: 100).items.count

        let list = try HistoryListCommand.parse([])
        try list.run(output: Capture().output, store: store)
        let get = try HistoryGetCommand.parse([token.id])
        try get.run(output: Capture().output, store: store)
        #expect(try store.listPage(limit: 100).items.count == before)
    }

    private func runJSONGet(_ id: String, store: OperationHistoryStore) throws -> HistoryDetailResult {
        let command = try HistoryGetCommand.parse([id])
        let capture = Capture()
        try command.run(output: capture.output, store: store)
        return try JSONDecoder.history.decode(HistoryDetailResult.self, from: Data(capture.stdout.utf8))
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""
        var output: CLIOutput {
            CLIOutput(stdout: { [self] in stdout += $0 }, stderr: { [self] in stderr += $0 })
        }
    }

    private struct Fixture {
        let parent: URL
        let root: URL

        init(createRoot: Bool = true) throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("applebookscli-history-command-\(UUID().uuidString)", isDirectory: true)
            root = parent.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if createRoot {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            }
        }

        func store(now: Date? = nil) -> OperationHistoryStore {
            let fixed = now ?? date("2026-09-04T10:00:00Z")
            return OperationHistoryStore(root: root, now: { fixed }, timeZone: { TimeZone(secondsFromGMT: 0)! })
        }

        func date(_ value: String) -> Date {
            ISO8601DateFormatter().date(from: value)!
        }

        func remove() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

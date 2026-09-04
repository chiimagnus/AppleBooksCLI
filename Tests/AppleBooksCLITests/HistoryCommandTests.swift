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
        let store = fixture.store(now: fixed)
        let first = try store.begin(operation: "collections.create", arguments: ["collections", "create", "private title"])
        try store.complete(first, exitCode: 0, stdout: "first", stderr: "")
        let second = try store.begin(operation: "annotations.update-note", arguments: ["annotations", "update-note", "--note", "private note"])
        try store.complete(second, exitCode: 1, stdout: "", stderr: "private-error-secret")

        let command = try HistoryListCommand.parse(["--json"])
        let capture = Capture()
        try command.run(output: capture.output, store: store)
        let result = try JSONDecoder.history.decode(HistoryListResult.self, from: Data(capture.stdout.utf8))
        #expect(result.items.map(\.id) == [first.id, second.id].sorted())
        #expect(capture.stdout.contains("private title") == false)
        #expect(capture.stdout.contains("private note") == false)
        #expect(capture.stdout.contains("private-error-secret") == false)
        #expect(capture.stderr.isEmpty)
    }

    @Test
    func getDistinguishesCompletedEmptyStreamsFromIncompleteNil() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let completed = try store.begin(operation: "sync", arguments: ["sync"])
        try store.complete(completed, exitCode: 0, stdout: "", stderr: "")
        let incomplete = try store.begin(operation: "collections.rename", arguments: ["collections", "rename", "id"])

        let completedResult = try runJSONGet(completed.id, store: store)
        #expect(completedResult.status == .success)
        #expect(completedResult.stdout == "")
        #expect(completedResult.stderr == "")
        #expect(completedResult.completedAt != nil)
        #expect(completedResult.exitCode == 0)

        let incompleteResult = try runJSONGet(incomplete.id, store: store)
        #expect(incompleteResult.status == .incomplete)
        #expect(incompleteResult.stdout == nil)
        #expect(incompleteResult.stderr == nil)
        #expect(incompleteResult.completedAt == nil)
        #expect(incompleteResult.exitCode == nil)
    }

    @Test
    func humanGetEscapesControlCharactersInsteadOfReplayingThem() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let token = try store.begin(
            operation: "annotations.update-note",
            arguments: ["annotations", "update-note", "--note", "line1\nline2\u{001B}[31m"]
        )
        try store.complete(token, exitCode: 0, stdout: "out\nnext\u{001B}[2J", stderr: "err\tvalue")

        let command = try HistoryGetCommand.parse([token.id])
        let capture = Capture()
        try command.run(output: capture.output, store: store)
        #expect(capture.stdout.contains("line1\\nline2"))
        #expect(capture.stdout.contains("\\u001b"))
        #expect(capture.stdout.contains("out\\nnext"))
        #expect(capture.stdout.contains("err\\tvalue"))
        #expect(capture.stdout.unicodeScalars.contains { $0.value == 0x1B } == false)
        #expect(capture.stderr.isEmpty)
    }

    @Test
    func missingRootIsEmptyOrNotFoundWithoutCreatingState() throws {
        let fixture = try Fixture(createRoot: false)
        defer { fixture.remove() }
        let store = fixture.store()
        let list = try HistoryListCommand.parse(["--json"])
        let listCapture = Capture()
        try list.run(output: listCapture.output, store: store)
        let result = try JSONDecoder.history.decode(HistoryListResult.self, from: Data(listCapture.stdout.utf8))
        #expect(result.items.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path) == false)

        let get = try HistoryGetCommand.parse(["00000000-0000-4000-8000-000000000000", "--json"])
        #expect(throws: CLIError.notFound("Operation history entry not found.")) {
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
        let command = try HistoryListCommand.parse(["--json"])

        do {
            try command.run(output: Capture().output, store: fixture.store(now: fixture.date("2026-09-04T10:00:00Z")))
            Issue.record("expected unavailable")
        } catch let error as CLIError {
            #expect(error == .unavailable("Operation history is unavailable."))
            #expect(error.message.contains(privatePayload) == false)
            #expect(error.message.contains(fixture.root.path) == false)
        }
    }

    @Test
    func listAndGetDoNotCreateRecursiveHistory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store()
        let token = try store.begin(operation: "sync", arguments: ["sync"])
        try store.complete(token, exitCode: 0, stdout: "ok", stderr: "")
        let before = try store.list().count

        let list = try HistoryListCommand.parse(["--json"])
        try list.run(output: Capture().output, store: store)
        let get = try HistoryGetCommand.parse([token.id, "--json"])
        try get.run(output: Capture().output, store: store)
        #expect(try store.list().count == before)
    }

    private func runJSONGet(_ id: String, store: OperationHistoryStore) throws -> HistoryDetailResult {
        let command = try HistoryGetCommand.parse([id, "--json"])
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

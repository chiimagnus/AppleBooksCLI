import Darwin
import Dispatch
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("OperationHistoryTests")
struct OperationHistoryTests {
    @Test
    func beginCompleteAndIncompleteFoldIntoDistinctStatuses() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let start = date("2026-09-04T10:00:00Z")
        let store = fixture.store(at: start)

        let success = try store.begin(operation: "collections.create", arguments: ["collections", "create", "Shelf"])
        try fixture.store(at: start.addingTimeInterval(1)).complete(
            success,
            exitCode: 0,
            stdout: #"{"committed":true}"# + "\n",
            stderr: ""
        )
        let failure = try store.begin(operation: "annotations.update-note", arguments: ["annotations", "update-note", "uuid", "--note", "private"])
        try fixture.store(at: start.addingTimeInterval(2)).complete(
            failure,
            exitCode: 64,
            stdout: "",
            stderr: "Error: rejected\n"
        )
        let incomplete = try store.begin(operation: "sync", arguments: ["sync"])

        let records = try fixture.store(at: start.addingTimeInterval(3)).list()
        #expect(records.count == 3)
        #expect(records.first(where: { $0.id == success.id })?.status == .success)
        #expect(records.first(where: { $0.id == failure.id })?.status == .failure)
        #expect(records.first(where: { $0.id == incomplete.id })?.status == .incomplete)
        #expect(records.first(where: { $0.id == failure.id })?.arguments.last == "private")
        #expect(records.first(where: { $0.id == success.id })?.stdout == #"{"committed":true}"# + "\n")
        #expect(records.first(where: { $0.id == incomplete.id })?.stdout == nil)
        #expect(try fixture.store(at: start.addingTimeInterval(3)).get(id: "missing") == nil)
    }

    @Test
    func missingRootReadsAsEmptyWithoutCreatingState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store(at: date("2026-09-04T10:00:00Z"))

        #expect(try store.list().isEmpty)
        #expect(try store.get(id: "missing") == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.root.path) == false)
    }

    @Test
    func crossMidnightCompletionStaysInStartedDateFileAndLongRunExpiresCleanly() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let startedAt = date("2026-09-04T23:59:30Z")
        let token = try fixture.store(at: startedAt).begin(operation: "collections.rename", arguments: ["collections", "rename"])
        try fixture.store(at: date("2026-09-05T00:01:00Z")).complete(token, exitCode: 0, stdout: "ok\n", stderr: "")

        #expect(try fixture.dateFileNames() == ["2026-09-04.jsonl"])
        #expect(try fixture.store(at: date("2026-09-05T00:01:01Z")).get(id: token.id)?.status == .success)

        let oldFixture = try Fixture()
        defer { oldFixture.cleanup() }
        let oldStart = date("2026-09-01T00:00:00Z")
        let old = try oldFixture.store(at: oldStart).begin(operation: "sync", arguments: ["sync"])
        try oldFixture.store(at: oldStart.addingTimeInterval(25 * 60 * 60)).complete(old, exitCode: 0, stdout: "", stderr: "")
        #expect(try oldFixture.store(at: oldStart.addingTimeInterval(25 * 60 * 60)).list().isEmpty)
        #expect(try oldFixture.dateFileNames().isEmpty)
    }

    @Test
    func retentionUsesAbsoluteStartedAtCompactsFilesAndCleansOnlyOwnedTemps() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reference = date("2026-09-04T12:00:00Z")
        let expiredAt = reference.addingTimeInterval(-25 * 60 * 60)
        let retainedAt = reference.addingTimeInterval(-23 * 60 * 60)

        let expired = try fixture.store(at: expiredAt).begin(operation: "collections.create", arguments: ["expired"])
        try fixture.store(at: expiredAt.addingTimeInterval(1)).complete(expired, exitCode: 0, stdout: "expired\n", stderr: "")
        let retained = try fixture.store(at: retainedAt).begin(operation: "collections.create", arguments: ["retained"])
        try fixture.store(at: retainedAt.addingTimeInterval(1)).complete(retained, exitCode: 0, stdout: "retained\n", stderr: "")

        let unknown = fixture.root.appendingPathComponent("keep-me.txt")
        try Data("user file".utf8).write(to: unknown)
        let staleTemp = fixture.root.appendingPathComponent(".operation-history-\(UUID().uuidString.lowercased()).tmp")
        try Data("private stale data".utf8).write(to: staleTemp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staleTemp.path)

        let records = try fixture.store(at: reference).list()
        #expect(records.map(\.id) == [retained.id])
        #expect(try fixture.store(at: reference).get(id: expired.id) == nil)
        #expect(FileManager.default.fileExists(atPath: staleTemp.path) == false)
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        let lines = try fixture.jsonLines()
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { $0.contains(retained.id) })
    }

    @Test
    func retentionIgnoresDatePartitionTimezone() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let reference = date("2026-09-04T12:00:00Z")
        let retainedAt = reference.addingTimeInterval(-23 * 60 * 60)
        let expiredAt = reference.addingTimeInterval(-25 * 60 * 60)
        let plus14 = TimeZone(secondsFromGMT: 14 * 60 * 60)!
        let minus12 = TimeZone(secondsFromGMT: -12 * 60 * 60)!

        let retained = try fixture.store(at: retainedAt, timeZone: plus14).begin(operation: "sync", arguments: ["retained"])
        try fixture.store(at: retainedAt.addingTimeInterval(1), timeZone: plus14).complete(retained, exitCode: 0, stdout: "", stderr: "")
        let expired = try fixture.store(at: expiredAt, timeZone: minus12).begin(operation: "sync", arguments: ["expired"])
        try fixture.store(at: expiredAt.addingTimeInterval(1), timeZone: minus12).complete(expired, exitCode: 0, stdout: "", stderr: "")

        let records = try fixture.store(at: reference).list()
        #expect(records.map(\.id) == [retained.id])
        #expect(try fixture.store(at: reference).get(id: expired.id) == nil)
    }

    @Test
    func historyArtifactsAreOwnerOnlyAndExistingBroadModesAreTightened() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fixture.root.path)
        let token = try fixture.store(at: date("2026-09-04T10:00:00Z")).begin(operation: "sync", arguments: ["sync"])
        try fixture.store(at: date("2026-09-04T10:00:01Z")).complete(token, exitCode: 0, stdout: "", stderr: "")

        #expect(try mode(at: fixture.root) == 0o700)
        #expect(try mode(at: fixture.root.appendingPathComponent(".lock")) == 0o600)
        let dateFile = try #require(fixture.dateFileNames().first)
        #expect(try mode(at: fixture.root.appendingPathComponent(dateFile)) == 0o600)
    }

    @Test
    func controlledSymlinkAndWrongTypeFailClosedWithoutTouchingTarget() throws {
        let symlinkFixture = try Fixture(createRoot: true)
        defer { symlinkFixture.cleanup() }
        let outside = symlinkFixture.parent.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: symlinkFixture.root.appendingPathComponent("2026-09-04.jsonl"),
            withDestinationURL: outside
        )
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try symlinkFixture.store(at: date("2026-09-04T12:00:00Z")).list()
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")

        let directoryFixture = try Fixture(createRoot: true)
        defer { directoryFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: directoryFixture.root.appendingPathComponent("2026-09-04.jsonl"),
            withIntermediateDirectories: false
        )
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try directoryFixture.store(at: date("2026-09-04T12:00:00Z")).list()
        }
    }

    @Test
    func concurrentStoresSerializeWholeJsonLinesWithoutDroppingOperations() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let failures = FailureBox()
        let store = fixture.store()

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            let token: OperationHistoryToken
            do {
                token = try store.begin(operation: "collections.create", arguments: ["Shelf-\(index)"])
            } catch {
                failures.append("begin[\(index)]: \(error)")
                return
            }
            do {
                try store.complete(token, exitCode: 0, stdout: "ok-\(index)\n", stderr: "")
            } catch {
                failures.append("complete[\(index)]: \(error)")
            }
        }

        #expect(failures.isEmpty)
        let records = try store.list()
        #expect(records.count == 16)
        #expect(Set(records.map(\.id)).count == 16)
        #expect(records.allSatisfy { $0.status == .success })
        for line in try fixture.jsonLines() {
            #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
        }
    }

    @Test
    func trailingPartialLineIsRecoveredBeforeNextAppend() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let first = try fixture.store(at: time).begin(operation: "sync", arguments: ["first"])
        try fixture.store(at: time.addingTimeInterval(1)).complete(first, exitCode: 0, stdout: "", stderr: "")
        let file = try fixture.onlyDateFile()
        try append(Data(#"{"partial""#.utf8), to: file)

        let second = try fixture.store(at: time.addingTimeInterval(2)).begin(operation: "sync", arguments: ["second"])
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("partial") == false)
        let records = try fixture.store(at: time.addingTimeInterval(3)).list()
        #expect(Set(records.map(\.id)) == Set([first.id, second.id]))
        #expect(records.first(where: { $0.id == second.id })?.status == .incomplete)
    }

    @Test
    func completeMalformedLineUnknownSchemaAndDuplicateEventsFailClosed() throws {
        let malformed = try Fixture()
        defer { malformed.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        _ = try malformed.store(at: time).begin(operation: "sync", arguments: ["sync"])
        try append(Data("{bad json}\n".utf8), to: malformed.onlyDateFile())
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try malformed.store(at: time).list()
        }

        let unknownSchema = try Fixture()
        defer { unknownSchema.cleanup() }
        _ = try unknownSchema.store(at: time).begin(operation: "sync", arguments: ["sync"])
        let unknownFile = try unknownSchema.onlyDateFile()
        let original = try String(contentsOf: unknownFile, encoding: .utf8)
        try original.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
            .write(to: unknownFile, atomically: false, encoding: .utf8)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try unknownSchema.store(at: time).list()
        }

        let duplicate = try Fixture()
        defer { duplicate.cleanup() }
        _ = try duplicate.store(at: time).begin(operation: "sync", arguments: ["sync"])
        let duplicateFile = try duplicate.onlyDateFile()
        let firstLine = try #require(String(contentsOf: duplicateFile, encoding: .utf8).split(separator: "\n").first)
        try append(Data((String(firstLine) + "\n").utf8), to: duplicateFile)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try duplicate.store(at: time).list()
        }
    }

    @Test
    func orphanCompletedEventFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let token = try fixture.store(at: time).begin(operation: "sync", arguments: ["sync"])
        try fixture.store(at: time.addingTimeInterval(1)).complete(token, exitCode: 0, stdout: "", stderr: "")
        let file = try fixture.onlyDateFile()
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        try (String(lines[1]) + "\n").write(to: file, atomically: false, encoding: .utf8)

        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try fixture.store(at: time.addingTimeInterval(2)).list()
        }
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func mode(at url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw OperationHistoryStoreError.unavailable }
        return info.st_mode & mode_t(0o777)
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var failures: [String] = []

        var isEmpty: Bool {
            lock.lock()
            defer { lock.unlock() }
            return failures.isEmpty
        }

        func append(_ failure: String) {
            lock.lock()
            failures.append(failure)
            lock.unlock()
        }
    }

    private final class Fixture {
        let parent: URL
        let root: URL

        init(createRoot: Bool = false) throws {
            parent = FileManager.default.temporaryDirectory
                .appendingPathComponent("applebookscli-history-\(UUID().uuidString)", isDirectory: true)
                .resolvingSymlinksInPath()
            root = parent.appendingPathComponent("history", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if createRoot {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            }
        }

        func store(
            at time: Date = Date(),
            timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!
        ) -> OperationHistoryStore {
            OperationHistoryStore(root: root, now: { time }, timeZone: { timeZone })
        }

        func dateFileNames() throws -> [String] {
            guard FileManager.default.fileExists(atPath: root.path) else { return [] }
            return try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".jsonl") }
                .sorted()
        }

        func onlyDateFile() throws -> URL {
            let name = try #require(dateFileNames().first)
            return root.appendingPathComponent(name)
        }

        func jsonLines() throws -> [String] {
            var lines: [String] = []
            for name in try dateFileNames() {
                let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
                lines += text.split(separator: "\n").map(String.init)
            }
            return lines
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}

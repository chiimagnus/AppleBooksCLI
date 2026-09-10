import Darwin
import Dispatch
import Foundation
import Testing
@testable import AppleBooksCore
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

        let finalStore = fixture.store(at: start.addingTimeInterval(3))
        let page = try finalStore.listPage(limit: 100)
        #expect(page.items.count == 3)
        #expect(page.items.first(where: { $0.id == success.id })?.status == .success)
        #expect(page.items.first(where: { $0.id == failure.id })?.status == .failure)
        #expect(page.items.first(where: { $0.id == incomplete.id })?.status == .incomplete)
        #expect(try finalStore.get(id: failure.id)?.arguments.last == "private")
        #expect(try finalStore.get(id: success.id)?.stdout == #"{"committed":true}"# + "\n")
        #expect(try finalStore.get(id: incomplete.id)?.stdout == nil)
        #expect(try finalStore.get(id: "00000000-0000-4000-8000-000000000000") == nil)
    }

    @Test
    func missingRootReadsAsEmptyWithoutCreatingState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store(at: date("2026-09-04T10:00:00Z"))

        #expect(try store.listPage().items.isEmpty)
        #expect(try store.get(id: "00000000-0000-4000-8000-000000000000") == nil)
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
        #expect(try oldFixture.store(at: oldStart.addingTimeInterval(25 * 60 * 60)).listPage().items.isEmpty)
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
        let unknownTempLike = fixture.root.appendingPathComponent(
            ".operation-history-550E8400-E29B-41D4-A716-446655440000.tmp"
        )
        try Data("user temp-like file".utf8).write(to: unknownTempLike)

        let records = try fixture.store(at: reference).listPage(limit: 100).items
        #expect(records.map(\.id) == [retained.id])
        #expect(try fixture.store(at: reference).get(id: expired.id) == nil)
        #expect(FileManager.default.fileExists(atPath: staleTemp.path) == false)
        #expect(FileManager.default.fileExists(atPath: unknownTempLike.path))
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

        let records = try fixture.store(at: reference).listPage(limit: 100).items
        #expect(records.map(\.id) == [retained.id])
        #expect(try fixture.store(at: reference).get(id: expired.id) == nil)
    }

    @Test
    func beginDeletesDefinitelyExpiredDateFilesWithoutParsingTheirEvents() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        for day in 1...31 {
            let name = String(format: "2026-08-%02d.jsonl", day)
            try Data("{malformed expired history}\n".utf8).write(to: fixture.root.appendingPathComponent(name))
        }

        _ = try fixture.store(at: date("2026-09-04T12:00:00Z")).begin(operation: "sync", arguments: ["sync"])
        #expect(try fixture.dateFileNames() == ["2026-09-04.jsonl"])
    }

    @Test
    func rootReplacementDuringBeginFailsClosedBeforeCallerCanProceed() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        let moved = fixture.parent.appendingPathComponent("history-moved", isDirectory: true)
        let replacer = RootReplacementBox(root: fixture.root, moved: moved)
        let fixed = date("2026-09-04T10:00:00Z")
        let store = OperationHistoryStore(
            root: fixture.root,
            now: { fixed },
            timeZone: { replacer.replaceAndReturnUTC() }
        )

        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try store.begin(operation: "sync", arguments: ["sync"])
        }
        #expect(replacer.failure == nil)
        #expect(FileManager.default.fileExists(atPath: moved.path))
        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
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
            _ = try symlinkFixture.store(at: date("2026-09-04T12:00:00Z")).listPage()
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")

        let directoryFixture = try Fixture(createRoot: true)
        defer { directoryFixture.cleanup() }
        try FileManager.default.createDirectory(
            at: directoryFixture.root.appendingPathComponent("2026-09-04.jsonl"),
            withIntermediateDirectories: false
        )
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try directoryFixture.store(at: date("2026-09-04T12:00:00Z")).listPage()
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
        let records = try store.listPage(limit: 100).items
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
        let records = try fixture.store(at: time.addingTimeInterval(3)).listPage(limit: 100).items
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
            _ = try malformed.store(at: time).listPage()
        }

        let unknownSchema = try Fixture()
        defer { unknownSchema.cleanup() }
        _ = try unknownSchema.store(at: time).begin(operation: "sync", arguments: ["sync"])
        let unknownFile = try unknownSchema.onlyDateFile()
        let original = try String(contentsOf: unknownFile, encoding: .utf8)
        try original.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#)
            .write(to: unknownFile, atomically: false, encoding: .utf8)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try unknownSchema.store(at: time).listPage()
        }

        let duplicate = try Fixture()
        defer { duplicate.cleanup() }
        _ = try duplicate.store(at: time).begin(operation: "sync", arguments: ["sync"])
        let duplicateFile = try duplicate.onlyDateFile()
        let firstLine = try #require(String(contentsOf: duplicateFile, encoding: .utf8).split(separator: "\n").first)
        try append(Data((String(firstLine) + "\n").utf8), to: duplicateFile)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try duplicate.store(at: time).listPage()
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
            _ = try fixture.store(at: time.addingTimeInterval(2)).listPage()
        }
    }

    @Test
    func cursorPaginationStaysBoundedAcrossTenThousandEvents() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        let startedAt = date("2026-09-04T10:00:00Z")
        let ids = try fixture.writeStartedEvents(count: 10_005, startedAt: startedAt)
        for index in 0..<1_000 {
            try Data().write(to: fixture.root.appendingPathComponent(String(format: "noise-%05d", index)))
        }
        let peak = PeakBox()
        let store = fixture.store(
            at: startedAt.addingTimeInterval(60),
            observeListCandidateCount: peak.observe
        )

        let first = try store.listPage()
        #expect(first.items.map(\.id) == Array(ids.prefix(20)))
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)
        let second = try store.listPage(limit: 20, cursor: cursor)
        #expect(second.items.map(\.id) == Array(ids.dropFirst(20).prefix(20)))
        #expect(Set(first.items.map(\.id)).isDisjoint(with: Set(second.items.map(\.id))))
        #expect(peak.value <= 21)

        let exact = try store.get(id: ids.last!)
        #expect(exact?.id == ids.last)
        #expect(exact?.status == .incomplete)
    }

    @Test
    func cursorStalesAfterHistoryStoreGenerationChanges() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let store = fixture.store(at: time)
        for index in 0..<25 {
            _ = try store.begin(operation: "sync", arguments: ["sync", "\(index)"])
        }
        let first = try store.listPage(limit: 20)
        let cursor = try #require(first.nextCursor)
        _ = try store.begin(operation: "sync", arguments: ["sync", "new"])
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try store.listPage(limit: 20, cursor: cursor)
        }
    }

    @Test
    func cursorStalesAfterDateFileReplacement() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        _ = try fixture.writeStartedEvents(count: 25, startedAt: time)
        let store = fixture.store(at: time.addingTimeInterval(60))
        let first = try store.listPage()
        let cursor = try #require(first.nextCursor)
        let file = try fixture.onlyDateFile()
        let replacement = fixture.root.appendingPathComponent("replacement.tmp")
        try Data(contentsOf: file).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)

        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try store.listPage(cursor: cursor)
        }
    }

    @Test
    func cursorStalesAfterBoundaryPruneRewrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let oldTime = date("2026-09-04T10:00:00Z")
        _ = try fixture.store(at: oldTime).begin(operation: "sync", arguments: ["old"])
        let retainedTime = date("2026-09-04T12:00:00Z")
        for index in 0..<25 {
            _ = try fixture.store(at: retainedTime).begin(operation: "sync", arguments: ["retained", "\(index)"])
        }
        let firstStore = fixture.store(at: date("2026-09-05T09:00:00Z"))
        let first = try firstStore.listPage()
        let cursor = try #require(first.nextCursor)

        let advanced = fixture.store(at: date("2026-09-05T11:00:00Z"))
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try advanced.listPage(cursor: cursor)
        }
        #expect(try advanced.listPage(limit: 100).items.count == 25)
    }

    @Test
    func malformedPublicIDsFailBeforeHistoryRootIO() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        let target = fixture.parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: target)
        let store = fixture.store(at: date("2026-09-04T10:00:00Z"))

        for invalid in [
            "00000000-0000-4000-8000-00000000000",
            "00000000-0000-4000-8000-0000000000000",
            "00000000-0000-4000-8000-00000000000A",
            String(repeating: "x", count: 4_096),
            "历史-00000000-0000-4000-8000-000000000000",
        ] {
            #expect(throws: OperationHistoryStoreError.invalidID) {
                _ = try store.get(id: invalid)
            }
        }
    }

    @Test
    func activeCompletionValidatesOnlyItsStartedDateFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let token = try fixture.store(at: time).begin(operation: "sync", arguments: ["sync"])
        try Data("{bad unrelated history}\n".utf8).write(
            to: fixture.root.appendingPathComponent("2026-09-03.jsonl")
        )

        try fixture.store(at: time.addingTimeInterval(1)).complete(token, exitCode: 0, stdout: "ok", stderr: "")
        let target = fixture.root.appendingPathComponent("2026-09-04.jsonl")
        let lines = try String(contentsOf: target, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
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

    private final class RootReplacementBox: @unchecked Sendable {
        private let lock = NSLock()
        private let root: URL
        private let moved: URL
        private var replaced = false
        private(set) var failure: String?

        init(root: URL, moved: URL) {
            self.root = root
            self.moved = moved
        }

        func replaceAndReturnUTC() -> TimeZone {
            lock.lock()
            defer { lock.unlock() }
            guard replaced == false else { return TimeZone(secondsFromGMT: 0)! }
            replaced = true
            do {
                try FileManager.default.moveItem(at: root, to: moved)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            } catch {
                failure = String(describing: error)
            }
            return TimeZone(secondsFromGMT: 0)!
        }
    }

    private final class PeakBox: @unchecked Sendable {
        private let lock = NSLock()
        private var peak = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return peak
        }

        func observe(_ count: Int) {
            lock.lock()
            peak = max(peak, count)
            lock.unlock()
        }
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
            timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!,
            observeListCandidateCount: @escaping @Sendable (Int) -> Void = { _ in }
        ) -> OperationHistoryStore {
            OperationHistoryStore(
                root: root,
                now: { time },
                timeZone: { timeZone },
                observeListCandidateCount: observeListCandidateCount
            )
        }

        func writeStartedEvents(count: Int, startedAt: Date) throws -> [String] {
            let file = root.appendingPathComponent("2026-09-04.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let timestamp = ISO8601DateFormatter().string(from: startedAt)
            var ids: [String] = []
            ids.reserveCapacity(count)
            for index in 0..<count {
                let id = String(
                    format: "00000000-0000-4000-8000-%012llx",
                    UInt64(index)
                )
                ids.append(id)
                let line = "{\"arguments\":[\"sync\"],\"id\":\"\(id)\",\"kind\":\"started\",\"operation\":\"sync\",\"schemaVersion\":1,\"startedAt\":\"\(timestamp)\"}\n"
                try handle.write(contentsOf: Data(line.utf8))
            }
            return ids
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

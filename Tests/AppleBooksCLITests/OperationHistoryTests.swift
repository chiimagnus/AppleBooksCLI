import Darwin
import Dispatch
import Foundation
import Testing
@testable import AppleBooksCore
@testable import AppleBooksCLI

extension OperationHistoryStore {
    func beginTestHistory(
        operation: String,
        request: OperationHistoryRequest = .unavailable
    ) throws -> OperationHistoryToken {
        guard case let .started(token) = try begin(
            operation: operation,
            request: request,
            operationID: nil
        ) else {
            throw OperationHistoryStoreError.unavailable
        }
        return token
    }

    func completeTestHistory(_ token: OperationHistoryToken, exitCode: Int32) throws {
        try complete(token, exitCode: exitCode, completion: nil)
    }
}

@Suite("OperationHistoryTests")
struct OperationHistoryTests {
    @Test
    func beginCompleteAndIncompleteFoldIntoDistinctStatuses() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let start = date("2026-09-04T10:00:00Z")
        let store = fixture.store(at: start)

        let success = try store.beginTestHistory(operation: "collections.create")
        try fixture.store(at: start.addingTimeInterval(1)).completeTestHistory(
            success,
            exitCode: 0)
        let failure = try store.beginTestHistory(operation: "annotations.update-note")
        try fixture.store(at: start.addingTimeInterval(2)).completeTestHistory(
            failure,
            exitCode: 64)
        let incomplete = try store.beginTestHistory(operation: "sync")

        let finalStore = fixture.store(at: start.addingTimeInterval(3))
        let page = try finalStore.listPage(limit: 100)
        #expect(page.items.count == 3)
        #expect(page.items.first(where: { $0.id == success.id })?.status == .success)
        #expect(page.items.first(where: { $0.id == failure.id })?.status == .failure)
        #expect(page.items.first(where: { $0.id == incomplete.id })?.status == .incomplete)
        #expect(try finalStore.get(id: failure.id)?.request == .unavailable)
        #expect(try finalStore.get(id: success.id)?.result == .unavailable)
        #expect(try finalStore.get(id: success.id)?.inverse == .unavailable)
        #expect(try finalStore.get(id: incomplete.id)?.result == nil)
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
        let token = try fixture.store(at: startedAt).beginTestHistory(operation: "collections.rename")
        try fixture.store(at: date("2026-09-05T00:01:00Z")).completeTestHistory(token, exitCode: 0)

        #expect(try fixture.dateFileNames() == ["2026-09-04.jsonl"])
        #expect(try fixture.store(at: date("2026-09-05T00:01:01Z")).get(id: token.id)?.status == .success)

        let oldFixture = try Fixture()
        defer { oldFixture.cleanup() }
        let oldStart = date("2026-09-01T00:00:00Z")
        let old = try oldFixture.store(at: oldStart).beginTestHistory(operation: "sync")
        try oldFixture.store(at: oldStart.addingTimeInterval(25 * 60 * 60)).completeTestHistory(old, exitCode: 0)
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

        let expired = try fixture.store(at: expiredAt).beginTestHistory(operation: "collections.create")
        try fixture.store(at: expiredAt.addingTimeInterval(1)).completeTestHistory(expired, exitCode: 0)
        let retained = try fixture.store(at: retainedAt).beginTestHistory(operation: "collections.create")
        try fixture.store(at: retainedAt.addingTimeInterval(1)).completeTestHistory(retained, exitCode: 0)

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

        let retained = try fixture.store(at: retainedAt, timeZone: plus14).beginTestHistory(operation: "sync")
        try fixture.store(at: retainedAt.addingTimeInterval(1), timeZone: plus14).completeTestHistory(retained, exitCode: 0)
        let expired = try fixture.store(at: expiredAt, timeZone: minus12).beginTestHistory(operation: "sync")
        try fixture.store(at: expiredAt.addingTimeInterval(1), timeZone: minus12).completeTestHistory(expired, exitCode: 0)

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

        _ = try fixture.store(at: date("2026-09-04T12:00:00Z")).beginTestHistory(operation: "sync")
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
            _ = try store.beginTestHistory(operation: "sync")
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
        let token = try fixture.store(at: date("2026-09-04T10:00:00Z")).beginTestHistory(operation: "sync")
        try fixture.store(at: date("2026-09-04T10:00:01Z")).completeTestHistory(token, exitCode: 0)

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
                token = try store.beginTestHistory(operation: "collections.create")
            } catch {
                failures.append("begin[\(index)]: \(error)")
                return
            }
            do {
                try store.completeTestHistory(token, exitCode: 0)
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
    func operationIDClaimIsAtomicAcrossConcurrentStores() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = fixture.store(at: date("2026-09-04T10:00:00Z"))
        let operationID = "11111111-1111-4111-8111-111111111111"
        let started = CounterBox()
        let replays = CounterBox()
        let failures = FailureBox()

        DispatchQueue.concurrentPerform(iterations: 16) { index in
            do {
                switch try store.begin(
                    operation: "collections.create",
                    request: OperationHistoryRequest(title: "Retry Shelf"),
                    operationID: operationID
                ) {
                case .started:
                    started.increment()
                case .replay:
                    replays.increment()
                case .conflict:
                    failures.append("conflict[\(index)]")
                }
            } catch {
                failures.append("claim[\(index)]: \(error)")
            }
        }

        #expect(failures.isEmpty)
        #expect(started.value == 1)
        #expect(replays.value == 15)
        let record = try #require(try store.get(id: operationID))
        #expect(record.status == .incomplete)
        #expect(record.operation == "collections.create")
        #expect(record.request.title == "Retry Shelf")
        #expect(try store.listPage(limit: 100).items.count == 1)
    }

    @Test
    func operationIDReplayAndConflictReuseHistoryIdentityWithoutRedispatch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let operationID = "22222222-2222-4222-8222-222222222222"
        let request = OperationHistoryRequest(title: "Retry Shelf")
        let store = fixture.store(at: date("2026-09-04T10:00:00Z"))

        let token: OperationHistoryToken
        switch try store.begin(operation: "collections.create", request: request, operationID: operationID) {
        case let .started(value): token = value
        case .replay, .conflict: throw OperationHistoryStoreError.unavailable
        }
        #expect(token.id == operationID)
        try fixture.store(at: date("2026-09-04T10:00:01Z")).completeTestHistory(token, exitCode: 0)

        switch try store.begin(operation: "collections.create", request: request, operationID: operationID) {
        case .replay:
            let record = try #require(try store.get(id: operationID))
            #expect(record.status == .success)
            #expect(record.id == operationID)
        case .started, .conflict:
            Issue.record("completed operation ID should replay-block")
        }

        switch try store.begin(
            operation: "collections.create",
            request: OperationHistoryRequest(title: "Different Shelf"),
            operationID: operationID
        ) {
        case .conflict:
            let record = try #require(try store.get(id: operationID))
            #expect(record.id == operationID)
            #expect(record.request == request)
        case .started, .replay:
            Issue.record("same operation ID with different request should conflict")
        }

        #expect(throws: OperationHistoryStoreError.invalidID) {
            _ = try store.begin(operation: "sync", request: .unavailable, operationID: "NOT-A-UUID")
        }
        #expect(try store.listPage(limit: 100).items.count == 1)
    }

    @Test
    func trailingPartialLineIsRecoveredBeforeNextAppend() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let first = try fixture.store(at: time).beginTestHistory(operation: "sync")
        try fixture.store(at: time.addingTimeInterval(1)).completeTestHistory(first, exitCode: 0)
        let file = try fixture.onlyDateFile()
        try append(Data(#"{"partial""#.utf8), to: file)

        let second = try fixture.store(at: time.addingTimeInterval(2)).beginTestHistory(operation: "sync")
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
        _ = try malformed.store(at: time).beginTestHistory(operation: "sync")
        try append(Data("{bad json}\n".utf8), to: malformed.onlyDateFile())
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try malformed.store(at: time).listPage()
        }

        let unknownSchema = try Fixture()
        defer { unknownSchema.cleanup() }
        _ = try unknownSchema.store(at: time).beginTestHistory(operation: "sync")
        let unknownFile = try unknownSchema.onlyDateFile()
        let original = try String(contentsOf: unknownFile, encoding: .utf8)
        try original.replacingOccurrences(of: #""schemaVersion":2"#, with: #""schemaVersion":999"#)
            .write(to: unknownFile, atomically: false, encoding: .utf8)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try unknownSchema.store(at: time).listPage()
        }

        let duplicate = try Fixture()
        defer { duplicate.cleanup() }
        _ = try duplicate.store(at: time).beginTestHistory(operation: "sync")
        let duplicateFile = try duplicate.onlyDateFile()
        let firstLine = try #require(String(contentsOf: duplicateFile, encoding: .utf8).split(separator: "\n").first)
        try append(Data((String(firstLine) + "\n").utf8), to: duplicateFile)
        #expect(throws: OperationHistoryStoreError.unavailable) {
            _ = try duplicate.store(at: time).listPage()
        }
    }

    @Test
    func oversizedV1PayloadsMigrateWithBoundedLineBufferAndNoGuessedInverse() throws {
        let startedAt = date("2026-09-04T10:00:00Z")
        for payloadBytes in [1 * 1_024 * 1_024 + 17, 64 * 1_024 * 1_024 + 17] {
            let fixture = try Fixture(createRoot: true)
            defer { fixture.cleanup() }
            let id = UUID().uuidString.lowercased()
            try fixture.writeLegacyPair(payloadBytes: payloadBytes, id: id, startedAt: startedAt)
            let peak = PeakBox()
            let stored = try fixture.store(
                at: startedAt.addingTimeInterval(1),
                observeLineBufferedBytes: peak.observe
            ).get(id: id)
            let record = try #require(stored)

            #expect(record.status == .success)
            #expect(record.request == .unavailable)
            #expect(record.result == .unavailable)
            #expect(record.inverse == .unavailable)
            #expect(peak.value <= 256 * 1_024)
        }
    }

    @Test
    func oversizedInverseFallsBackToUnavailableWithoutLosingOutcome() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let store = fixture.store(at: time)
        let token = try store.beginTestHistory(
            operation: "collections.rename",
            request: OperationHistoryRequest(
                selector: OperationHistorySelector(collectionID: "collection-id"),
                title: "new-title"
            )
        )
        let outcome = OperationHistoryResult(
            kind: .mutation,
            committed: true,
            changed: true,
            acknowledgementRequested: false,
            acknowledged: nil,
            verified: nil,
            collectionPendingBefore: nil,
            annotationPendingBefore: nil,
            warningCodes: []
        )
        try fixture.store(at: time.addingTimeInterval(1)).complete(
            token,
            exitCode: 0,
            completion: OperationHistoryCompletion(
                result: outcome,
                inverse: OperationHistoryInverse(
                    available: true,
                    operation: "collections.rename",
                    selector: OperationHistorySelector(collectionID: "collection-id"),
                    noteAction: nil,
                    title: String(repeating: "x", count: 300 * 1_024)
                )
            )
        )

        let stored = try fixture.store(at: time.addingTimeInterval(2)).get(id: token.id)
        let record = try #require(stored)
        #expect(record.result == outcome)
        #expect(record.inverse == .unavailable)
        #expect(record.status == .success)
    }

    @Test
    func malformedV1EventAddsMigrationWarningWithoutPoisoningValidHistory() throws {
        let fixture = try Fixture(createRoot: true)
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let file = fixture.root.appendingPathComponent("2026-09-04.jsonl")
        try Data("{\"schemaVersion\":1,\"kind\":\"started\",\"id\":\"broken\"\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let valid = try fixture.store(at: time).beginTestHistory(operation: "sync")
        let warnings = CounterBox()

        let page = try fixture.store(
            at: time.addingTimeInterval(1),
            observeMigrationWarning: warnings.increment
        ).listPage(limit: 100)

        #expect(page.items.map(\.id) == [valid.id])
        #expect(warnings.value == 1)
    }

    @Test
    func orphanCompletedEventFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let time = date("2026-09-04T10:00:00Z")
        let token = try fixture.store(at: time).beginTestHistory(operation: "sync")
        try fixture.store(at: time.addingTimeInterval(1)).completeTestHistory(token, exitCode: 0)
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
        for _ in 0..<25 {
            _ = try store.beginTestHistory(operation: "sync")
        }
        let first = try store.listPage(limit: 20)
        let cursor = try #require(first.nextCursor)
        _ = try store.beginTestHistory(operation: "sync")
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
        _ = try fixture.store(at: oldTime).beginTestHistory(operation: "sync")
        let retainedTime = date("2026-09-04T12:00:00Z")
        for _ in 0..<25 {
            _ = try fixture.store(at: retainedTime).beginTestHistory(operation: "sync")
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
        let token = try fixture.store(at: time).beginTestHistory(operation: "sync")
        try Data("{bad unrelated history}\n".utf8).write(
            to: fixture.root.appendingPathComponent("2026-09-03.jsonl")
        )

        try fixture.store(at: time.addingTimeInterval(1)).completeTestHistory(token, exitCode: 0)
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

    private final class CounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
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
            observeListCandidateCount: @escaping @Sendable (Int) -> Void = { _ in },
            observeLineBufferedBytes: @escaping @Sendable (Int) -> Void = { _ in },
            observeMigrationWarning: @escaping @Sendable () -> Void = {}
        ) -> OperationHistoryStore {
            OperationHistoryStore(
                root: root,
                now: { time },
                timeZone: { timeZone },
                observeListCandidateCount: observeListCandidateCount,
                observeLineBufferedBytes: observeLineBufferedBytes,
                observeMigrationWarning: observeMigrationWarning
            )
        }

        func writeLegacyPair(payloadBytes: Int, id: String, startedAt: Date) throws {
            if FileManager.default.fileExists(atPath: root.path) == false {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            }
            let file = root.appendingPathComponent("2026-09-04.jsonl")
            FileManager.default.createFile(atPath: file.path, contents: nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            let timestamp = ISO8601DateFormatter().string(from: startedAt)
            let started = "{\"arguments\":[\"sync\"],\"id\":\"\(id)\",\"kind\":\"started\",\"operation\":\"sync\",\"schemaVersion\":1,\"startedAt\":\"\(timestamp)\"}\n"
            try handle.write(contentsOf: Data(started.utf8))
            let completedPrefix = "{\"completedAt\":\"\(timestamp)\",\"exitCode\":0,\"id\":\"\(id)\",\"kind\":\"completed\",\"schemaVersion\":1,\"stderr\":\"\",\"stdout\":\""
            try handle.write(contentsOf: Data(completedPrefix.utf8))
            let chunk = Data(repeating: 0x78, count: 64 * 1_024)
            var remaining = payloadBytes
            while remaining > 0 {
                let count = min(remaining, chunk.count)
                try handle.write(contentsOf: chunk.prefix(count))
                remaining -= count
            }
            try handle.write(contentsOf: Data("\"}\n".utf8))
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

import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("MutationCoordinatorLifecycleTests")
struct MutationCoordinatorLifecycleTests {
    @Test
    func runningStateQuitsBeforeBackupAndRelaunchesAfterReadBack() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in fixture.state.events.append("preflight") },
            revalidate: { _ in fixture.state.events.append("revalidate") },
            mutation: { handle in
                fixture.state.events.append("mutation")
                try self.setValue(handle, "after")
                return Int64(7)
            },
            invariant: { _, _ in fixture.state.events.append("invariant") },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running)
        try assertOrdered(
            ["preflight", "terminate", "backup", "revalidate", "mutation", "invariant", "readBack", "launch"],
            in: fixture.state.events
        )
    }

    @Test
    func cloudProjectionRunsAfterReadBackBeforeRelaunch() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(8)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in fixture.state.events.append("cloudProjection") },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        try assertOrdered(["readBack", "cloudProjection", "launch"], in: fixture.state.events)
    }

    @Test
    func cloudProjectionFailureIsCommittedWarningAndStillRelaunches() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(9)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in
                fixture.state.events.append("cloudProjection")
                throw TestFailure.cloudProjection
            },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(result.localPK == 9)
        #expect(result.warnings == [.cloudProjectionFailed])
        try assertOrdered(["readBack", "cloudProjection", "launch"], in: fixture.state.events)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func readBackFailureSkipsCloudProjectionAndReportsBothWarnings() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }
        var projectionCount = 0

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(10)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in projectionCount += 1 },
            readBack: { _, _ in throw TestFailure.readBack }
        )

        #expect(result.committed)
        #expect(result.warnings == [.readBackFailed, .cloudProjectionFailed])
        #expect(projectionCount == 0)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func originallyClosedNeverTerminatesOrLaunches() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in fixture.state.events.append("preflight") },
            revalidate: { _ in fixture.state.events.append("revalidate") },
            mutation: { handle in
                try self.setValue(handle, "after")
                return ()
            },
            domainData: { _ in MutationDomainData(changed: true) },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(fixture.state.events.contains("backup"))
        #expect(fixture.state.events.contains("terminate") == false)
        #expect(fixture.state.events.contains("launch") == false)
        #expect(fixture.state.running == false)
    }

    @Test
    func quitFailureCreatesNoBackupAndNeverOpensWritableRail() throws {
        let fixture = try fixture(running: true, terminateSucceeds: false)
        defer { fixture.remove() }
        var revalidateCount = 0

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in revalidateCount += 1 },
                mutation: { _ in () },
                domainData: { _ in MutationDomainData(changed: false) },
                readBack: { _, _ in }
            )
            Issue.record("expected quit failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .quitFailed)
            #expect(failure.backupHandle == nil)
            #expect(failure.warnings.isEmpty)
        }

        #expect(fixture.state.events.contains("terminate"))
        #expect(fixture.state.events.contains("backup") == false)
        #expect(fixture.state.events.contains("launch") == false)
        #expect(revalidateCount == 0)
        #expect(try readValue(at: fixture.database) == "before")
    }

    @Test
    func backupFailureAfterQuitRestoresOriginalRunningStateWithoutWritableOpen() throws {
        let fixture = try fixture(running: true, backupFails: true)
        defer { fixture.remove() }
        var revalidateCount = 0

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in revalidateCount += 1 },
                mutation: { _ in () },
                domainData: { _ in MutationDomainData(changed: false) },
                readBack: { _, _ in }
            )
            Issue.record("expected backup failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .backupFailed)
            #expect(failure.backupHandle == nil)
            #expect(failure.warnings.isEmpty)
        }

        try assertOrdered(["terminate", "backup", "launch"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(revalidateCount == 0)
        #expect(try readValue(at: fixture.database) == "before")
    }

    @Test
    func transactionFailureRollsBackBeforeRestoringRunningState() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in fixture.state.events.append("revalidate") },
                mutation: { handle in
                    fixture.state.events.append("mutation")
                    try self.setValue(handle, "partial")
                    throw TestFailure.mutation
                },
                domainData: { (_: Void) in MutationDomainData(changed: true) },
                readBack: { _, _ in Issue.record("read-back must not run") }
            )
            Issue.record("expected mutation failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .mutationFailed)
            #expect(failure.backupHandle == "library-test-backup.sqlite")
            #expect(failure.warnings.isEmpty)
        }

        try assertOrdered(["backup", "revalidate", "mutation", "launch"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "before")
    }

    @Test
    func committedRelaunchFailureIsSuccessWarning() throws {
        let fixture = try fixture(running: true, launchFails: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(9)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(result.localPK == 9)
        #expect(result.warnings == [.relaunchFailed])
        try assertOrdered(["backup", "readBack", "launch"], in: fixture.state.events)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func committedReadBackFailureStillRelaunchesAndReturnsWarning() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(10)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { _, _ in
                fixture.state.events.append("readBack")
                throw TestFailure.readBack
            }
        )

        #expect(result.committed)
        #expect(result.warnings == [.readBackFailed])
        try assertOrdered(["readBack", "launch"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func recoveryLaunchFailureDoesNotMaskPrimaryBackupFailure() throws {
        let fixture = try fixture(running: true, backupFails: true, launchFails: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
                mutation: { _ in () },
                domainData: { _ in MutationDomainData(changed: false) },
                readBack: { _, _ in }
            )
            Issue.record("expected backup failure")
        } catch let failure as MutationFailure {
            #expect(failure.code == .backupFailed)
            #expect(failure.warnings == [.relaunchFailed])
        }
    }

    private func fixture(
        running: Bool,
        terminateSucceeds: Bool = true,
        backupFails: Bool = false,
        launchFails: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database)
        let state = LifecycleState(
            running: running,
            terminateSucceeds: terminateSucceeds,
            launchFails: launchFails
        )
        let backupURL = root.appendingPathComponent("library-test-backup.sqlite")
        let coordinator = MutationCoordinator(
            database: database,
            backupRoot: root.appendingPathComponent("backups"),
            booksApp: state.controller(),
            backupAction: { _ in
                state.events.append("backup")
                #expect(state.running == false)
                if backupFails { throw TestFailure.backup }
                return backupURL
            }
        )
        return Fixture(root: root, database: database, state: state, coordinator: coordinator)
    }

    private func createDatabase(_ url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw TestFailure.setup
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('before')", nil, nil, nil) == SQLITE_OK else {
            throw TestFailure.setup
        }
    }

    private func setValue(_ handle: OpaquePointer, _ value: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE sample SET value=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw TestFailure.mutation }
        defer { sqlite3_finalize(statement) }
        let bind = value.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw TestFailure.mutation }
    }

    private func readValue(at url: URL) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: url.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func assertOrdered(_ required: [String], in events: [String]) throws {
        var cursor = events.startIndex
        for item in required {
            guard let index = events[cursor...].firstIndex(of: item) else {
                Issue.record("missing lifecycle event: \(item); events=\(events)")
                return
            }
            cursor = events.index(after: index)
        }
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let state: LifecycleState
        let coordinator: MutationCoordinator

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private final class LifecycleState {
        var running: Bool
        var events: [String] = []
        let terminateSucceeds: Bool
        let launchFails: Bool

        init(running: Bool, terminateSucceeds: Bool, launchFails: Bool) {
            self.running = running
            self.terminateSucceeds = terminateSucceeds
            self.launchFails = launchFails
        }

        func controller() -> BooksAppController {
            BooksAppController(
                isRunning: { [self] in
                    events.append("isRunning")
                    return running
                },
                terminate: { [self] in
                    events.append("terminate")
                    guard terminateSucceeds else { return false }
                    running = false
                    return true
                },
                launch: { [self] in
                    events.append("launch")
                    if launchFails { throw TestFailure.launch }
                    running = true
                }
            )
        }
    }

    private enum TestFailure: Error, Equatable {
        case setup
        case backup
        case mutation
        case readBack
        case cloudProjection
        case launch
    }
}

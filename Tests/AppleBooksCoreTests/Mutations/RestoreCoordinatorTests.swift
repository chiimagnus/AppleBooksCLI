import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("RestoreCoordinatorTests")
struct RestoreCoordinatorTests {
    @Test
    func runningRestoreQuitsBeforeQuietSafetyBackupAndRestoresOriginalState() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)

        #expect(result.restoreApplied)
        #expect(result.verified)
        #expect(result.restoredFromHandle == fixture.selectedBackup.lastPathComponent)
        #expect(result.safetyBackupHandle.contains("/") == false)
        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "snapshot")
        try assertOrdered(["terminate", "backup", "launch"], in: fixture.state.events)
    }

    @Test
    func originallyClosedRestoreNeverTerminatesOrLaunches() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)

        #expect(result.restoreApplied)
        #expect(result.verified)
        #expect(fixture.state.running == false)
        #expect(fixture.state.events.contains("terminate") == false)
        #expect(fixture.state.events.contains("launch") == false)
        #expect(fixture.state.events.contains("backup"))
    }

    @Test
    func rejectedHandleFailsBeforeLifecycleOrSafetyBackup() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }
        let countBefore = try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count

        do {
            _ = try fixture.coordinator.restoreLibrary(handle: "../\(fixture.selectedBackup.lastPathComponent)")
            Issue.record("expected source rejection")
        } catch let failure as RestoreFailure {
            #expect(failure.restoreApplied == false)
            #expect(failure.code == .sourceRejected)
            #expect(failure.safetyBackupHandle == nil)
            #expect(failure.warnings.isEmpty)
        }

        #expect(fixture.state.events.isEmpty)
        #expect(fixture.state.running)
        #expect(try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count == countBefore)
        #expect(try readValue(at: fixture.database) == "current")
    }

    @Test
    func quitFailureCreatesNoSafetyBackupAndDoesNotRestore() throws {
        let fixture = try fixture(running: true, terminateSucceeds: false)
        defer { fixture.remove() }
        let countBefore = try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count

        do {
            _ = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)
            Issue.record("expected quit failure")
        } catch let failure as RestoreFailure {
            #expect(failure.restoreApplied == false)
            #expect(failure.code == .quitFailed)
            #expect(failure.safetyBackupHandle == nil)
            #expect(failure.warnings.isEmpty)
        }

        #expect(fixture.state.events.contains("terminate"))
        #expect(fixture.state.events.contains("backup") == false)
        #expect(fixture.state.events.contains("launch") == false)
        #expect(try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count == countBefore)
        #expect(try readValue(at: fixture.database) == "current")
    }

    @Test
    func safetyBackupFailureAfterQuitRestoresOriginalRunningState() throws {
        let fixture = try fixture(running: true, backupFails: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)
            Issue.record("expected safety backup failure")
        } catch let failure as RestoreFailure {
            #expect(failure.restoreApplied == false)
            #expect(failure.code == .safetyBackupFailed)
            #expect(failure.safetyBackupHandle == nil)
            #expect(failure.warnings.isEmpty)
        }

        try assertOrdered(["terminate", "backup", "launch"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "current")
    }

    @Test
    func restoreFailureKeepsSafetyHandleAndRestoresOriginalRunningState() throws {
        let fixture = try fixture(running: true, large: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.coordinator.restoreLibrary(
                handle: fixture.selectedBackup.lastPathComponent,
                pageCount: 1,
                failAfterSteps: 1
            )
            Issue.record("expected restore failure")
        } catch let failure as RestoreFailure {
            #expect(failure.restoreApplied == false)
            #expect(failure.code == .restoreFailed)
            #expect(failure.safetyBackupHandle != nil)
            #expect(failure.safetyBackupHandle?.contains("/") == false)
            #expect(failure.warnings.isEmpty)
        }

        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "current")
        try SQLiteBackup.verifyIntegrity(of: fixture.database)
    }

    @Test
    func selectedBackupMayRotateAwayAfterItsReadOnlyHandleIsOpened() throws {
        let fixture = try fixture(running: false, safetyKeep: 1)
        defer { fixture.remove() }
        let selectedHandle = fixture.selectedBackup.lastPathComponent
        #expect(FileManager.default.fileExists(atPath: fixture.selectedBackup.path))

        let result = try fixture.coordinator.restoreLibrary(handle: selectedHandle)

        #expect(result.restoreApplied)
        #expect(result.verified)
        #expect(FileManager.default.fileExists(atPath: fixture.selectedBackup.path) == false)
        #expect(try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count == 1)
        #expect(try readValue(at: fixture.database) == "snapshot")
    }

    @Test
    func postApplyVerificationFailureReturnsAppliedUnverifiedOutcome() throws {
        let fixture = try fixture(running: false, verificationFails: true)
        defer { fixture.remove() }
        let countBefore = try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count

        let result = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)

        #expect(result.restoreApplied)
        #expect(result.verified == false)
        #expect(result.warnings == [.verificationFailed])
        #expect(try readValue(at: fixture.database) == "snapshot")
        #expect(try completedBackups(in: fixture.backupRoot, stem: "BKLibrary").count == countBefore + 1)
    }

    @Test
    func relaunchFailureIsAppliedSuccessWarning() throws {
        let fixture = try fixture(running: true, launchFails: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.restoreLibrary(handle: fixture.selectedBackup.lastPathComponent)

        #expect(result.restoreApplied)
        #expect(result.verified)
        #expect(result.warnings == [.relaunchFailed])
        #expect(try readValue(at: fixture.database) == "snapshot")
    }

    @Test
    func facadeRestoresOnlyByOpaqueLibraryHandle() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }
        let books = try AppleBooks(
            libraryDB: fixture.database,
            annotationsDB: fixture.database,
            historicalConfig: nil,
            collectionWriter: CollectionWriter(database: fixture.database),
            libraryBackupRoot: fixture.backupRoot,
            restoreCoordinator: fixture.coordinator
        )

        let result = try books.restoreLibraryBackup(handle: fixture.selectedBackup.lastPathComponent)

        #expect(result.restoreApplied)
        #expect(result.restoredFromHandle == fixture.selectedBackup.lastPathComponent)
        #expect(result.restoredFromHandle.contains("/") == false)
        #expect(result.safetyBackupHandle.contains("/") == false)
    }

    private func fixture(
        running: Bool,
        terminateSucceeds: Bool = true,
        launchFails: Bool = false,
        backupFails: Bool = false,
        safetyKeep: Int = 10,
        large: Bool = false,
        verificationFails: Bool = false
    ) throws -> Fixture {
        let root = temporaryDirectory()
        let database = try database(at: root.appendingPathComponent("BKLibrary.sqlite"), value: "snapshot", large: large)
        let backupRoot = root.appendingPathComponent("backups")
        let selectedBackup = try SQLiteBackup.create(source: database, backupRoot: backupRoot, keep: 10)
        try setValue(database, value: "current")
        let state = LifecycleState(
            running: running,
            terminateSucceeds: terminateSucceeds,
            launchFails: launchFails
        )
        let coordinator = coordinator(
            database: database,
            backupRoot: backupRoot,
            keep: safetyKeep,
            state: state,
            backupFails: backupFails,
            verificationFails: verificationFails
        )
        return Fixture(
            root: root,
            database: database,
            backupRoot: backupRoot,
            selectedBackup: selectedBackup,
            state: state,
            coordinator: coordinator
        )
    }

    private func coordinator(
        database: URL,
        backupRoot: URL,
        keep: Int,
        state: LifecycleState,
        backupFails: Bool,
        verificationFails: Bool
    ) -> MutationCoordinator {
        MutationCoordinator(
            database: database,
            backupRoot: backupRoot,
            keep: keep,
            booksApp: state.controller(),
            backupAction: { preserving in
                state.events.append("backup")
                #expect(state.running == false)
                if backupFails { throw TestFailure.backup }
                return try SQLiteBackup.create(
                    source: database,
                    backupRoot: backupRoot,
                    keep: keep,
                    preserving: preserving
                )
            },
            restoreVerificationAction: verificationFails ? {
                state.events.append("verify")
                throw TestFailure.verification
            } : nil
        )
    }

    private func database(at url: URL, value: String, large: Bool) throws -> URL {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw TestFailure.setup }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE sample(value TEXT); CREATE TABLE padding(value BLOB);", nil, nil, nil) == SQLITE_OK else {
            throw TestFailure.setup
        }
        try execute(handle, sql: "INSERT INTO sample VALUES(?)", text: value)
        if large {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO padding VALUES(zeroblob(1048576))", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw TestFailure.setup }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw TestFailure.setup }
        }
        return url
    }

    private func enableWALAndSetValue(_ url: URL, value: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw TestFailure.setup }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else { throw TestFailure.setup }
        try execute(handle, sql: "UPDATE sample SET value=?", text: value)
    }

    private func setValue(_ url: URL, value: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw TestFailure.setup }
        defer { sqlite3_close_v2(handle) }
        try execute(handle, sql: "UPDATE sample SET value=?", text: value)
    }

    private func execute(_ handle: OpaquePointer, sql: String, text: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TestFailure.setup
        }
        defer { sqlite3_finalize(statement) }
        let bind = text.withCString {
            sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard bind == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw TestFailure.setup }
    }

    private func readValue(at url: URL) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: url.path)
        defer { try? connection.close() }
        let statement = try connection.prepare("SELECT value FROM sample")
        guard try statement.step() else { return nil }
        return try SQLiteRow(statement: statement).text("value")
    }

    private func completedBackups(in root: URL, stem: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { BackupMetadata.parse(filename: $0.lastPathComponent, sourceStem: stem) != nil }
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

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct Fixture {
        let root: URL
        let database: URL
        let backupRoot: URL
        let selectedBackup: URL
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
        case verification
        case launch
    }
}

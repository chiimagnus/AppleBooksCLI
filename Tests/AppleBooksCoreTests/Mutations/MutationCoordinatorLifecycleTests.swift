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
            ["preflight", "terminate", "backup", "revalidate", "mutation", "invariant", "readBack", "launchWithoutActivation"],
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
        try assertOrdered(["readBack", "cloudProjection", "launchWithoutActivation"], in: fixture.state.events)
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
        try assertOrdered(["readBack", "cloudProjection", "launchWithoutActivation"], in: fixture.state.events)
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
    func acknowledgementRunsAfterProjectionBeforeFinalRestore() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(12)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in fixture.state.events.append("cloudProjection") },
            acknowledgementRequested: true,
            acknowledgement: { _, _ in fixture.state.events.append("acknowledgement") },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.warnings.isEmpty)
        #expect(result.acknowledgementRequested)
        #expect(result.acknowledged == true)
        try assertOrdered(
            ["readBack", "cloudProjection", "acknowledgement", "launchWithoutActivation"],
            in: fixture.state.events
        )
    }

    @Test
    func requestedAcknowledgementAfterReadBackFailureReportsEachEvidenceLayerOnce() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }
        var projectionCount = 0
        var acknowledgementCount = 0

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(13)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in projectionCount += 1 },
            acknowledgementRequested: true,
            acknowledgement: { _, _ in acknowledgementCount += 1 },
            readBack: { _, _ in throw TestFailure.readBack }
        )

        #expect(result.warnings == [.readBackFailed, .cloudProjectionFailed, .cloudSyncFailed])
        #expect(result.acknowledgementRequested)
        #expect(result.acknowledged == false)
        #expect(projectionCount == 0)
        #expect(acknowledgementCount == 0)
    }

    @Test
    func changedFalseSkipsProjectionAndRequestedAcknowledgement() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }
        var projectionCount = 0
        var acknowledgementCount = 0

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { _ in () },
            domainData: { _ in MutationDomainData(changed: false) },
            cloudProjection: { _ in projectionCount += 1 },
            acknowledgementRequested: true,
            acknowledgement: { _, _ in acknowledgementCount += 1 },
            readBack: { _, _ in }
        )

        #expect(result.committed == false)
        #expect(result.backupHandle == nil)
        #expect(result.changed == false)
        #expect(result.acknowledgementRequested)
        #expect(result.acknowledged == nil)
        #expect(result.warnings.isEmpty)
        #expect(projectionCount == 0)
        #expect(acknowledgementCount == 0)
        #expect(fixture.state.events.contains("terminate") == false)
    }

    @Test
    func runningQuietNoOpRestoresBackgroundWithoutBackupOrWritableRail() throws {
        let fixture = try fixture(running: true)
        defer { fixture.remove() }
        var acknowledgementCount = 0

        let result = try fixture.coordinator.perform(
            preflight: { _ in fixture.state.events.append("preflight") },
            quietDecision: { _ in
                fixture.state.events.append("quietDecision")
                return .noChange(MutationDomainData(localPK: 41, stableID: "no-op", changed: false))
            },
            revalidate: { _ in Issue.record("writable rail must not open") },
            mutation: { _ in
                Issue.record("mutation must not run")
                return ()
            },
            domainData: { _ in MutationDomainData(changed: true) },
            cloudProjection: { _ in Issue.record("projection must not run") },
            acknowledgementRequested: true,
            acknowledgement: { _, _ in acknowledgementCount += 1 },
            readBack: { _, _ in Issue.record("read-back must not run") }
        )

        #expect(result.committed == false)
        #expect(result.changed == false)
        #expect(result.backupHandle == nil)
        #expect(result.acknowledgementRequested)
        #expect(result.acknowledged == nil)
        #expect(result.warnings.isEmpty)
        #expect(acknowledgementCount == 0)
        #expect(fixture.state.running)
        #expect(fixture.state.frontmost == false)
        #expect(fixture.state.events.contains("backup") == false)
        try assertOrdered(["preflight", "terminate", "quietDecision", "launchWithoutActivation"], in: fixture.state.events)
    }

    @Test
    func frontmostQuietNoOpRestoresFrontmostAndReportsRestoreFailureAsWarning() throws {
        let restored = try fixture(running: true, frontmost: true)
        defer { restored.remove() }
        let success = try restored.coordinator.perform(
            preflight: { _ in },
            quietDecision: { _ in .noChange(MutationDomainData(changed: false)) },
            revalidate: { _ in Issue.record("writable rail must not open") },
            mutation: { _ in () },
            domainData: { _ in MutationDomainData(changed: true) },
            readBack: { _, _ in }
        )
        #expect(success.committed == false)
        #expect(success.warnings.isEmpty)
        #expect(restored.state.running)
        #expect(restored.state.frontmost)
        #expect(restored.state.events.contains("backup") == false)
        try assertOrdered(["terminate", "launch", "activate"], in: restored.state.events)

        let failed = try fixture(running: true, launchFails: true)
        defer { failed.remove() }
        let warning = try failed.coordinator.perform(
            preflight: { _ in },
            quietDecision: { _ in .noChange(MutationDomainData(changed: false)) },
            revalidate: { _ in Issue.record("writable rail must not open") },
            mutation: { _ in () },
            domainData: { _ in MutationDomainData(changed: true) },
            readBack: { _, _ in }
        )
        #expect(warning.committed == false)
        #expect(warning.warnings == [.booksStateRestoreFailed])
        #expect(failed.state.events.contains("backup") == false)
    }

    @Test
    func requestedAcknowledgementRestoresOriginallyClosedBooksAfterTemporaryLaunch() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(14)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in },
            acknowledgementRequested: true,
            acknowledgement: { _, markTemporaryLaunch in
                fixture.state.events.append("temporaryLaunch")
                fixture.state.running = true
                markTemporaryLaunch()
            },
            readBack: { _, _ in }
        )

        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running == false)
        try assertOrdered(["temporaryLaunch", "terminate"], in: fixture.state.events)
    }

    @Test
    func unownedBooksLaunchDuringAcknowledgementIsNeverClosed() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(15)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in },
            acknowledgementRequested: true,
            acknowledgement: { _, _ in
                fixture.state.events.append("userLaunch")
                fixture.state.running = true
            },
            readBack: { _, _ in }
        )

        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running)
        #expect(fixture.state.events.contains("terminate") == false)
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

        try assertOrdered(["terminate", "backup", "launchWithoutActivation"], in: fixture.state.events)
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

        try assertOrdered(["backup", "revalidate", "mutation", "launchWithoutActivation"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "before")
    }

    @Test
    func preCommitFailureRestoresOriginalFrontmostState() throws {
        let fixture = try fixture(running: true, frontmost: true)
        defer { fixture.remove() }

        do {
            _ = try fixture.coordinator.perform(
                preflight: { _ in },
                revalidate: { _ in },
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
            #expect(failure.warnings.isEmpty)
        }

        #expect(try readValue(at: fixture.database) == "before")
        #expect(fixture.state.running)
        #expect(fixture.state.frontmost)
        try assertOrdered(["mutation", "launch", "activate"], in: fixture.state.events)
    }

    @Test
    func committedBooksStateRestoreFailureIsSuccessWarning() throws {
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
        #expect(result.warnings == [.booksStateRestoreFailed])
        try assertOrdered(["backup", "readBack", "launchWithoutActivation"], in: fixture.state.events)
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
        try assertOrdered(["readBack", "launchWithoutActivation"], in: fixture.state.events)
        #expect(fixture.state.running)
        #expect(try readValue(at: fixture.database) == "committed")
    }

    @Test
    func frontmostStateIsRestoredOnlyAfterReadBackAndActivation() throws {
        let fixture = try fixture(running: true, frontmost: true)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(11)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            readBack: { _, _ in fixture.state.events.append("readBack") }
        )

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running)
        #expect(fixture.state.frontmost)
        try assertOrdered(["terminate", "readBack", "launch", "activate"], in: fixture.state.events)
    }

    @Test
    func successfulDeeplinkOpenPrecedesFinalFrontmostRestore() throws {
        let fixture = try fixture(running: true, frontmost: true, openURLSucceeds: true)
        defer { fixture.remove() }
        let deeplink = "ibooks://assetid/sample#epubcfi(/6/2)"

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(14)
            },
            domainData: {
                MutationDomainData(localPK: $0, changed: true, appleBooksURL: deeplink)
            },
            readBack: { _, _ in }
        )

        #expect(result.committed)
        #expect(result.warnings.isEmpty)
        #expect(result.appleBooksURL == deeplink)
        #expect(fixture.state.openedURLs == [deeplink])
        #expect(fixture.state.frontmost)
        try assertOrdered(["openURL", "launch", "activate"], in: fixture.state.events)
    }

    @Test
    func deeplinkOpenFailureWarnsAndStillRestoresFrontmostState() throws {
        let fixture = try fixture(running: true, frontmost: true, openURLSucceeds: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(15)
            },
            domainData: {
                MutationDomainData(
                    localPK: $0,
                    changed: true,
                    appleBooksURL: "ibooks://assetid/sample#epubcfi(/6/2)"
                )
            },
            readBack: { _, _ in }
        )

        #expect(result.committed)
        #expect(result.warnings == [.deeplinkOpenFailed])
        #expect(fixture.state.frontmost)
        try assertOrdered(["openURL", "launch", "activate"], in: fixture.state.events)
    }

    @Test
    func acknowledgementFailureAfterTemporaryLaunchStillRestoresOriginallyClosedBooks() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(16)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in },
            acknowledgementRequested: true,
            acknowledgement: { _, markTemporaryLaunch in
                fixture.state.events.append("temporaryLaunch")
                fixture.state.running = true
                markTemporaryLaunch()
                throw TestFailure.cloudSync
            },
            readBack: { _, _ in }
        )

        #expect(result.committed)
        #expect(result.warnings == [.cloudSyncFailed])
        #expect(result.acknowledgementRequested)
        #expect(result.acknowledged == false)
        #expect(fixture.state.running == false)
        try assertOrdered(["temporaryLaunch", "terminate"], in: fixture.state.events)
    }

    @Test
    func closedCleanupFailureIsCommittedStateRestoreWarning() throws {
        let fixture = try fixture(running: false, terminateSucceeds: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(16)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in },
            acknowledgementRequested: true,
            acknowledgement: { _, markTemporaryLaunch in
                fixture.state.running = true
                markTemporaryLaunch()
            },
            readBack: { _, _ in }
        )

        #expect(result.committed)
        #expect(result.warnings == [.booksStateRestoreFailed])
        #expect(fixture.state.running)
        #expect(fixture.state.events.contains("terminate"))
    }

    @Test
    func frontmostUserClaimPreventsClosingOwnedTemporaryLaunch() throws {
        let fixture = try fixture(running: false)
        defer { fixture.remove() }

        let result = try fixture.coordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { handle in
                try self.setValue(handle, "committed")
                return Int64(17)
            },
            domainData: { MutationDomainData(localPK: $0, changed: true) },
            cloudProjection: { _ in },
            acknowledgementRequested: true,
            acknowledgement: { _, markTemporaryLaunch in
                fixture.state.running = true
                markTemporaryLaunch()
                fixture.state.frontmost = true
            },
            readBack: { _, _ in }
        )

        #expect(result.warnings.isEmpty)
        #expect(fixture.state.running)
        #expect(fixture.state.frontmost)
        #expect(fixture.state.events.contains("terminate") == false)
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
            #expect(failure.warnings == [.booksStateRestoreFailed])
        }
    }

    private func fixture(
        running: Bool,
        frontmost: Bool = false,
        terminateSucceeds: Bool = true,
        backupFails: Bool = false,
        launchFails: Bool = false,
        openURLSucceeds: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database)
        let state = LifecycleState(
            running: running,
            frontmost: frontmost,
            terminateSucceeds: terminateSucceeds,
            launchFails: launchFails,
            openURLSucceeds: openURLSucceeds
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
        var frontmost: Bool
        var events: [String] = []
        var openedURLs: [String] = []
        let terminateSucceeds: Bool
        let launchFails: Bool
        let openURLSucceeds: Bool

        init(
            running: Bool,
            frontmost: Bool,
            terminateSucceeds: Bool,
            launchFails: Bool,
            openURLSucceeds: Bool
        ) {
            self.running = running
            self.frontmost = frontmost
            self.terminateSucceeds = terminateSucceeds
            self.launchFails = launchFails
            self.openURLSucceeds = openURLSucceeds
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
                    frontmost = false
                    return true
                },
                launch: { [self] in
                    events.append("launch")
                    if launchFails { throw TestFailure.launch }
                    running = true
                },
                isFrontmost: { [self] in
                    events.append("isFrontmost")
                    return frontmost
                },
                launchWithoutActivation: { [self] in
                    events.append("launchWithoutActivation")
                    if launchFails { throw TestFailure.launch }
                    running = true
                    frontmost = false
                },
                activate: { [self] in
                    events.append("activate")
                    if launchFails { throw TestFailure.launch }
                    frontmost = true
                },
                openURL: { [self] url in
                    events.append("openURL")
                    openedURLs.append(url.absoluteString)
                    return openURLSucceeds
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
        case cloudSync
        case launch
    }
}

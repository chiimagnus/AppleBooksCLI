import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("BackupsCommandTests")
struct BackupsCommandTests {
    @Test
    func backupsHelpRegistersOnlyListAndRestoreSurface() {
        let capture = Capture()
        let code = CLIEntrypoint.run(arguments: ["backups", "--help"], output: capture.output)

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("list"))
        #expect(capture.stdout.contains("restore"))

        let restoreCapture = Capture()
        let restoreCode = CLIEntrypoint.run(arguments: ["backups", "restore", "--help"], output: restoreCapture.output)
        #expect(restoreCode == CLIProcessExit.success.rawValue)
        #expect(restoreCapture.stderr.isEmpty)
        #expect(restoreCapture.stdout.contains("backupID"))
        #expect(restoreCapture.stdout.lowercased().contains("handle") == false)
        #expect(restoreCapture.stdout.contains(".sqlite") == false)
    }

    @Test
    func listExposesOnlyOpaqueBackupIDsAndMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let backup = try fixture.createBackup()
        try Data("ignore".utf8).write(to: fixture.backupRoot.appendingPathComponent("arbitrary.sqlite"))
        try FileManager.default.createDirectory(
            at: fixture.backupRoot.appendingPathComponent("library__20260101-000000-000000__00000000-0000-0000-0000-000000000000.sqlite"),
            withIntermediateDirectories: false
        )

        let command = try BackupsListCommand.parse([])
        let result = try command.execute(using: fixture.books())

        let backupID = try #require(BackupMetadata.backupID(fromLegacyFilename: backup.lastPathComponent))
        #expect(result.items.count == 1)
        #expect(result.items[0].backupID == backupID)
        #expect(result.items[0].sizeBytes > 0)
        let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(encoded.contains(backup.lastPathComponent) == false)
        #expect(encoded.contains("library__") == false)
        #expect(encoded.contains(".sqlite") == false)
    }

    @Test
    func listIsFixedNewestTenAndRejectsBrowsePaginationBeforeDatabaseAccess() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)

        var metadata: [BackupMetadata] = []
        for index in 0..<12 {
            let item = BackupMetadata.fresh(
                sourceStem: "library",
                now: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!
            )
            metadata.append(item)
            try Data([UInt8(index)]).write(to: fixture.backupRoot.appendingPathComponent(item.filename))
        }

        let command = try BackupsListCommand.parse([])
        let result = try command.execute(using: fixture.books())
        #expect(result.items.count == SQLiteBackup.retentionCount)
        #expect(result.items.map(\.backupID) == Array(metadata.suffix(10).reversed().map(\.backupID)))
        #expect(result.items.allSatisfy { item in
            item.backupID.contains("/") == false
                && item.backupID.contains("library") == false
                && item.backupID.contains(".sqlite") == false
        })

        let missing = "/definitely/missing/applebookscli-backups-list.sqlite"
        let invalidCases = [
            ["backups", "list", "--all"],
            ["backups", "list", "--limit", "1"],
            ["backups", "list", "--offset", "1"],
            ["backups", "list", "--cursor", "opaque"],
        ]
        for arguments in invalidCases {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + ["--library-db", missing],
                output: capture.output
            )
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }
    }

    @Test
    func restoreUsesOpaqueBackupIDAndReturnsConsumableSafetyBackupID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.createBackup()
        let sourceID = try #require(BackupMetadata.backupID(fromLegacyFilename: source.lastPathComponent))
        try fixture.setValue("after-backup")
        let lifecycle = Lifecycle(running: true)
        let books = try fixture.books(lifecycle: lifecycle)
        let command = try BackupsRestoreCommand.parse([sourceID])

        let result = try command.execute(using: books)

        #expect(result.changed)
        #expect(result.status == .restoredVerified)
        #expect(result.verified)
        #expect(result.restoredFromBackupID == sourceID)
        #expect(result.safetyBackupID != sourceID)
        #expect(result.warningCodes.isEmpty)
        #expect(try fixture.value() == "before-backup")
        let safetyHandle = try SQLiteBackup.restoreHandle(backupID: result.safetyBackupID, destination: fixture.library)
        #expect(FileManager.default.fileExists(
            atPath: fixture.backupRoot.appendingPathComponent(safetyHandle).path
        ))
        #expect(lifecycle.terminateCount == 1)
        #expect(lifecycle.launchCount == 1)
        #expect(lifecycle.running)

        let second = try BackupsRestoreCommand.parse([result.safetyBackupID])
        let secondResult = try second.execute(using: fixture.books())
        #expect(secondResult.restoredFromBackupID == result.safetyBackupID)
        #expect(try fixture.value() == "after-backup")
    }

    @Test
    func missingAndCorruptBackupIDsShareStableNotFoundCode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        let missingMetadata = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        )
        let corruptMetadata = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_700_000_001),
            uuid: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        try Data("not sqlite".utf8).write(
            to: fixture.backupRoot.appendingPathComponent(corruptMetadata.filename)
        )
        let books = try fixture.books()

        for backupID in [missingMetadata.backupID, corruptMetadata.backupID] {
            let command = try BackupsRestoreCommand.parse([backupID])
            #expect(throws: CLIError.notFound("backupID is unavailable or invalid.")) {
                _ = try command.execute(using: books)
            }
        }
        #expect(try fixture.value() == "before-backup")
    }

    @Test
    func malformedBackupIDsFailBeforeDatabaseDiscoveryWithoutEchoingInput() {
        let valid = BackupMetadata.fresh(
            sourceStem: "library",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        ).backupID
        let invalidCases = [
            "../outside.sqlite",
            "library__20260101-000000-000000__33333333-3333-4333-8333-333333333333.sqlite",
            String(repeating: "x", count: BackupMetadata.backupIDLength + 1),
            valid.uppercased(),
            valid.replacingOccurrences(of: "abk1_", with: "abk2_"),
        ]
        let missing = "/definitely/missing/applebookscli-backup-id-preflight.sqlite"

        for backupID in invalidCases {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["backups", "restore", backupID, "--library-db", missing],
                output: capture.output
            )
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(backupID) == false)
            #expect(capture.stderr.contains("Database override") == false)
        }
    }

    @Test
    func runningBooksQuitFailureIsAStableWriteSafetyFailureBeforeSafetyBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.createBackup()
        let sourceID = try #require(BackupMetadata.backupID(fromLegacyFilename: source.lastPathComponent))
        let lifecycle = Lifecycle(running: true, terminateSucceeds: false)
        let command = try BackupsRestoreCommand.parse([sourceID])

        #expect(throws: CLIError.writeSafety("Library restore failed safely (quit_failed).")) {
            _ = try command.execute(using: fixture.books(lifecycle: lifecycle))
        }
        #expect(lifecycle.terminateCount == 1)
        #expect(lifecycle.launchCount == 0)
        #expect(try fixture.backupHandles() == [source.lastPathComponent])
    }

    @Test
    func safetyBackupFailureIsStableAndRelaunchesPreviouslyRunningBooks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.createBackup()
        let sourceID = try #require(BackupMetadata.backupID(fromLegacyFilename: source.lastPathComponent))
        let lifecycle = Lifecycle(running: true)
        let books = try fixture.books(lifecycle: lifecycle, backupAction: { _ in
            throw FixtureError.forcedBackupFailure
        })
        let command = try BackupsRestoreCommand.parse([sourceID])

        #expect(throws: CLIError.writeSafety("Library restore failed safely (safety_backup_failed).")) {
            _ = try command.execute(using: books)
        }
        #expect(lifecycle.terminateCount == 1)
        #expect(lifecycle.launchCount == 1)
        #expect(lifecycle.running)
        #expect(try fixture.value() == "before-backup")
    }

    @Test
    func restoreFailureEnvelopesNeverReflectRawBackupHandles() {
        let rawHandle = "BKLibrary-private__20260101-000000-000000__00000000-0000-4000-8000-000000000099.sqlite"
        let cases: [(RestoreFailureCode, CLIProcessExit)] = [
            (.sourceRejected, .notFound),
            (.safetyBackupFailed, .writeSafety),
            (.restoreFailed, .writeSafety),
        ]

        for (code, expectedExit) in cases {
            let failure = RestoreFailure(
                safetyBackupHandle: rawHandle,
                code: code,
                warnings: [],
                underlying: SQLiteBackupError.invalidRestoreSource
            )
            let translated: CLIError
            do {
                try CLIOperation.run { () throws -> Void in throw failure }
                Issue.record("Expected restore failure translation")
                continue
            } catch let error as CLIError {
                translated = error
            } catch {
                Issue.record("Expected CLIError translation")
                continue
            }
            let capture = Capture()
            let exit = CLIEntrypoint.presentRunError(translated, output: capture.output)
            #expect(exit == expectedExit.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(rawHandle) == false)
            #expect(capture.stderr.contains(".sqlite") == false)
            #expect(capture.stderr.contains("BKLibrary") == false)
        }
    }

    @Test
    func listStoreFailureMapsToStableUnavailableCode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not a directory".utf8).write(to: fixture.backupRoot)
        let command = try BackupsListCommand.parse([])

        #expect(throws: CLIError.unavailable("Apple Books backup store is unavailable.")) {
            _ = try command.execute(using: fixture.books())
        }
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""

        var output: CLIOutput {
            CLIOutput(stdout: { [self] in stdout += $0 }, stderr: { [self] in stderr += $0 })
        }
    }

    private final class Lifecycle {
        var running: Bool
        let terminateSucceeds: Bool
        var terminateCount = 0
        var launchCount = 0

        init(running: Bool, terminateSucceeds: Bool = true) {
            self.running = running
            self.terminateSucceeds = terminateSucceeds
        }

        var controller: BooksAppController {
            BooksAppController(
                isRunning: { [self] in running },
                terminate: { [self] in
                    terminateCount += 1
                    if terminateSucceeds { running = false }
                    return terminateSucceeds
                },
                launch: { [self] in
                    launchCount += 1
                    running = true
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
        let backupRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            backupRoot = root.appendingPathComponent("backups", isDirectory: true)
            try Self.execute(library, "CREATE TABLE state(value TEXT); INSERT INTO state VALUES('before-backup');")
            try Self.execute(annotations, "CREATE TABLE placeholder(value INTEGER);")
            try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
        }

        func createBackup() throws -> URL {
            try SQLiteBackup.create(source: library, backupRoot: backupRoot, keep: 10)
        }

        func books(
            lifecycle: Lifecycle = Lifecycle(running: false),
            backupAction: ((Set<String>) throws -> URL)? = nil
        ) throws -> AppleBooks {
            let coordinator = MutationCoordinator(
                database: library,
                backupRoot: backupRoot,
                booksApp: lifecycle.controller,
                backupAction: backupAction
            )
            return try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(
                    database: library,
                    backupRoot: backupRoot,
                    booksApp: lifecycle.controller
                ),
                libraryBackupRoot: backupRoot,
                restoreCoordinator: coordinator
            )
        }

        func setValue(_ value: String) throws {
            try Self.execute(library, "UPDATE state SET value='\(value.replacingOccurrences(of: "'", with: "''"))'")
        }

        func value() throws -> String? {
            let connection = try SQLiteConnection.readOnly(path: library.path)
            defer { try? connection.close() }
            let statement = try connection.prepare("SELECT value FROM state LIMIT 1")
            guard try statement.step(), let raw = sqlite3_column_text(statement.handle, 0) else { return nil }
            return String(cString: raw)
        }

        func backupHandles() throws -> [String] {
            try SQLiteBackup.list(source: library, backupRoot: backupRoot).map(\.handle)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func execute(_ database: URL, _ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }
    }

    private enum FixtureError: Error {
        case sqlite
        case forcedBackupFailure
    }
}

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
    }

    @Test
    func listExposesOnlyCoreSafeHandlesAndMetadata() throws {
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

        #expect(result.items.count == 1)
        #expect(result.items[0].handle == backup.lastPathComponent)
        #expect(result.items[0].sizeBytes > 0)
        #expect(result.humanDescription.contains(fixture.root.path) == false)
    }

    @Test
    func restoreUsesCoreLifecycleCreatesFreshSafetyBackupAndRestoresDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.createBackup()
        try fixture.setValue("after-backup")
        let lifecycle = Lifecycle(running: true)
        let books = try fixture.books(lifecycle: lifecycle)
        let command = try BackupsRestoreCommand.parse([source.lastPathComponent])

        let result = try command.execute(using: books)

        #expect(result.changed)
        #expect(result.status == .restoredVerified)
        #expect(result.verified)
        #expect(result.restoredFromHandle == source.lastPathComponent)
        #expect(result.safetyBackupHandle != source.lastPathComponent)
        #expect(result.warningCodes.isEmpty)
        #expect(try fixture.value() == "before-backup")
        #expect(FileManager.default.fileExists(
            atPath: fixture.backupRoot.appendingPathComponent(result.safetyBackupHandle).path
        ))
        #expect(lifecycle.terminateCount == 1)
        #expect(lifecycle.launchCount == 1)
        #expect(lifecycle.running)
    }

    @Test
    func invalidEscapeMissingAndCorruptHandlesShareStableNotFoundCode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.backupRoot, withIntermediateDirectories: true)
        let corruptMetadata = BackupMetadata.fresh(sourceStem: "library")
        try Data("not sqlite".utf8).write(
            to: fixture.backupRoot.appendingPathComponent(corruptMetadata.filename)
        )
        let books = try fixture.books()

        for handle in ["../outside.sqlite", "missing.sqlite", corruptMetadata.filename] {
            let command = try BackupsRestoreCommand.parse([handle])
            #expect(throws: CLIError.notFound("Backup handle is unavailable or invalid.")) {
                _ = try command.execute(using: books)
            }
        }
        #expect(try fixture.value() == "before-backup")
    }

    @Test
    func runningBooksQuitFailureIsAStableWriteSafetyFailureBeforeSafetyBackup() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.createBackup()
        let lifecycle = Lifecycle(running: true, terminateSucceeds: false)
        let command = try BackupsRestoreCommand.parse([source.lastPathComponent])

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
        let lifecycle = Lifecycle(running: true)
        let books = try fixture.books(lifecycle: lifecycle, backupAction: { _ in
            throw FixtureError.forcedBackupFailure
        })
        let command = try BackupsRestoreCommand.parse([source.lastPathComponent])

        #expect(throws: CLIError.writeSafety("Library restore failed safely (safety_backup_failed).")) {
            _ = try command.execute(using: books)
        }
        #expect(lifecycle.terminateCount == 1)
        #expect(lifecycle.launchCount == 1)
        #expect(lifecycle.running)
        #expect(try fixture.value() == "before-backup")
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

import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("AnnotationWriteCommandTests")
struct AnnotationWriteCommandTests {
    @Test
    func annotationsHelpRegistersMutationCommandsWithoutOperationalState() {
        var stdout = ""
        var stderr = ""
        let code = CLIEntrypoint.run(
            arguments: ["annotations", "--help"],
            output: CLIOutput(stdout: { stdout = $0 }, stderr: { stderr = $0 })
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(stderr.isEmpty)
        #expect(stdout.contains("update-note"))
        #expect(stdout.contains("delete"))
    }

    @Test
    func annotationMutationHelpExposesExplicitCloudSyncFlag() {
        for subcommand in ["update-note", "delete"] {
            var stdout = ""
            var stderr = ""
            let code = CLIEntrypoint.run(
                arguments: ["annotations", subcommand, "--help"],
                output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(stderr.isEmpty)
            #expect(stdout.contains("--sync"))
            #expect(stdout.contains("CloudKit"))
        }
    }

    @Test
    func syncFlagPreservesCommittedAnnotationWhenLiveCloudRailIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())
        let command = try AnnotationsUpdateNoteCommand.parse(["123", "--note", "sync me", "--sync"])
        let result = try command.execute(using: books)
        #expect(result.committed)
        #expect(result.warningCodes == ["cloud_sync_failed"])
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "sync me")
    }

    @Test
    func updateNoteKeepsNumericUUIDSeparateFromExplicitPKAndDoesNotEchoNote() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())
        let privateNote = "  private replacement\nnote  "

        let uuidCommand = try AnnotationsUpdateNoteCommand.parse(["123", "--note", privateNote])
        let uuidResult = try uuidCommand.execute(using: books)
        #expect(uuidResult.committed)
        #expect(uuidResult.changed)
        #expect(uuidResult.localPK == 1)
        #expect(uuidResult.stableID == "123")
        #expect(uuidResult.warningCodes.isEmpty)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == privateNote)
        #expect(uuidResult.humanDescription.contains(privateNote) == false)
        let encoded = String(decoding: try JSONEncoder().encode(uuidResult), as: UTF8.self)
        #expect(encoded.contains(privateNote) == false)

        let pkCommand = try AnnotationsUpdateNoteCommand.parse(["--pk", "123", "--note", "pk replacement"])
        let pkResult = try pkCommand.execute(using: books)
        #expect(pkResult.localPK == 123)
        #expect(pkResult.stableID == nil)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=123") == "pk replacement")
    }

    @Test
    func deleteUsesSameSelectorGrammarAndOnlySoftDeletes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())

        let command = try AnnotationsDeleteCommand.parse(["123"])
        let result = try command.execute(using: books)

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.localPK == 1)
        #expect(result.stableID == "123")
        #expect(try fixture.integer("SELECT COUNT(*) FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try fixture.integer("SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "old note")
    }

    @Test
    func selectorConflictsFailBeforeAnyDatabaseConstruction() throws {
        for arguments in [
            ["123", "--pk", "1", "--note", "new"],
            ["--note", "new"],
        ] {
            let command = try AnnotationsUpdateNoteCommand.parse(arguments)
            #expect(throws: ValidationError.self) {
                _ = try command.execute(using: nil)
            }
        }

        let delete = try AnnotationsDeleteCommand.parse(["123", "--pk", "1"])
        #expect(throws: ValidationError.self) {
            _ = try delete.execute(using: nil)
        }
    }

    @Test
    func coreOwnsNoteLengthAndDeletedSafetyRules() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())

        let empty = try AnnotationsUpdateNoteCommand.parse(["123", "--note", ""])
        #expect(throws: CLIError.usageInvalid("Annotation note length is invalid.")) {
            _ = try empty.execute(using: books)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)

        let tooLong = try AnnotationsUpdateNoteCommand.parse([
            "123", "--note", String(repeating: "x", count: 10_001),
        ])
        #expect(throws: CLIError.usageInvalid("Annotation note length is invalid.")) {
            _ = try tooLong.execute(using: books)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)

        try fixture.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1 WHERE Z_PK=1")
        let deleted = try AnnotationsDeleteCommand.parse(["123"])
        #expect(throws: CLIError.writeSafety("Annotation is not writable.")) {
            _ = try deleted.execute(using: books)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)
    }

    @Test
    func postCommitRelaunchFailureIsSuccessWithWarning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var running = true
        var terminateCount = 0
        var launchCount = 0
        let controller = BooksAppController(
            isRunning: { running },
            terminate: {
                terminateCount += 1
                running = false
                return true
            },
            launch: {
                launchCount += 1
                throw BooksAppControllerError.launchFailed
            },
            sleep: { _ in }
        )
        let books = try fixture.books(controller: controller)
        let command = try AnnotationsUpdateNoteCommand.parse(["123", "--note", "committed note"])

        let result = try command.execute(using: books)

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.warningCodes == ["relaunch_failed"])
        #expect(terminateCount == 1)
        #expect(launchCount == 1)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "committed note")
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
        let annotationBackupRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            annotationBackupRoot = root.appendingPathComponent("annotation-backups")

            try Self.execute(library, "CREATE TABLE placeholder(value INTEGER)")
            try Self.execute(annotations, """
                CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
                INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,123);
                CREATE TABLE ZAEANNOTATION(
                  Z_PK INTEGER PRIMARY KEY,
                  Z_ENT INTEGER,
                  Z_OPT INTEGER,
                  ZANNOTATIONDELETED INTEGER,
                  ZANNOTATIONUUID TEXT,
                  ZANNOTATIONNOTE TEXT,
                  ZANNOTATIONMODIFICATIONDATE REAL,
                  ZFUTUREPROOFING6 TEXT
                );
                INSERT INTO ZAEANNOTATION VALUES(1,17,3,0,'123','old note',1,'1');
                INSERT INTO ZAEANNOTATION VALUES(123,17,1,0,'other','other note',1,'1');
                """)
            try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
        }

        func books(controller: BooksAppController) throws -> AppleBooks {
            try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(
                    database: library,
                    backupRoot: root.appendingPathComponent("library-backups"),
                    booksApp: controller
                ),
                annotationWriter: AnnotationWriter(
                    database: annotations,
                    backupRoot: annotationBackupRoot,
                    booksApp: controller
                )
            )
        }

        func closedController() -> BooksAppController {
            BooksAppController(
                isRunning: { false },
                terminate: { true },
                launch: {},
                sleep: { _ in }
            )
        }

        func execute(_ sql: String) throws {
            try Self.execute(annotations, sql)
        }

        func integer(_ sql: String) throws -> Int64 {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(annotations.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.sqlite }
            return sqlite3_column_int64(statement, 0)
        }

        func text(_ sql: String) throws -> String? {
            var handle: OpaquePointer?
            guard sqlite3_open_v2(annotations.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.sqlite }
            guard let raw = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: raw)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func execute(_ database: URL, _ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }
    }

    private enum FixtureError: Error {
        case sqlite
    }
}

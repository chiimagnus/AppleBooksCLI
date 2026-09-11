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
        #expect(stdout.contains("restore"))
    }

    @Test
    func annotationMutationHelpExposesExplicitCloudSyncFlag() {
        for subcommand in ["update-note", "delete", "restore"] {
            var stdout = ""
            var stderr = ""
            let code = CLIEntrypoint.run(
                arguments: ["annotations", subcommand, "--help"],
                output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(stderr.isEmpty)
            #expect(stdout.contains("--sync"))
            #expect(stdout.contains("After local commit"))
            #expect(stdout.contains("current-Mac CloudKit"))
            if subcommand != "restore" {
                #expect(stdout.contains("projection"))
                #expect(stdout.contains("local-only") == false)
            }
            if subcommand == "update-note" {
                #expect(stdout.contains("--clear"))
                #expect(stdout.contains("--note") == false)
                #expect(stdout.contains("stdin"))
            }
        }
    }

    @Test
    func syncFlagPreservesCommittedAnnotationWhenLiveCloudRailIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())
        let command = try AnnotationsUpdateNoteCommand.parse(["123", "--sync"])
        let result = try withInput("sync me") { try command.execute(using: books, input: $0) }
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

        let uuidCommand = try AnnotationsUpdateNoteCommand.parse(["123"])
        let uuidResult = try withInput(privateNote) { try uuidCommand.execute(using: books, input: $0) }
        #expect(uuidResult.committed)
        #expect(uuidResult.changed)
        #expect(uuidResult.annotationUUID == "123")
        #expect(uuidResult.annotationLocalPK == nil)
        #expect(uuidResult.warningCodes.isEmpty)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == privateNote)
        let encoded = String(decoding: try JSONEncoder().encode(uuidResult), as: UTF8.self)
        #expect(encoded.contains(privateNote) == false)
        #expect(encoded.contains("appleBooksURL") == false)

        let pkCommand = try AnnotationsUpdateNoteCommand.parse(["--pk", "123"])
        let pkResult = try withInput("pk replacement") { try pkCommand.execute(using: books, input: $0) }
        #expect(pkResult.annotationUUID == "other")
        #expect(pkResult.annotationLocalPK == nil)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=123") == "pk replacement")
    }

    @Test
    func annotationMutationJSONHidesInternalBackupAndDeeplink() throws {
        let deeplink = "ibooks://assetid/asset-a#epubcfi(/6/2)"
        let backup = BackupMetadata.fresh(
            sourceStem: "annotations",
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
        )
        let result = AnnotationMutationCommandResult(
            MutationResult(
                committed: true,
                backupHandle: backup.filename,
                localPK: 7,
                stableID: "uuid-7",
                changed: true,
                acknowledgementRequested: true,
                acknowledged: false,
                warnings: [.cloudSyncFailed],
                appleBooksURL: deeplink
            ),
            selector: .uuid("uuid-7")
        )

        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AnnotationMutationCommandResult.self, from: data)
        #expect(decoded == result)
        #expect(decoded.committed)
        #expect(decoded.changed)
        #expect(decoded.acknowledgementRequested)
        #expect(decoded.acknowledged == false)
        #expect(decoded.annotationUUID == "uuid-7")
        #expect(decoded.annotationLocalPK == nil)
        #expect(decoded.warningCodes == ["cloud_sync_failed"])
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["backupID"] == nil)
        #expect(object["localPK"] == nil)
        #expect(object["stableID"] == nil)
        #expect(object["appleBooksURL"] == nil)
        #expect(String(decoding: data, as: UTF8.self).contains(deeplink) == false)
        #expect(String(decoding: data, as: UTF8.self).contains(backup.backupID) == false)
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
        #expect(result.annotationUUID == "123")
        #expect(result.annotationLocalPK == nil)
        #expect(try fixture.integer("SELECT COUNT(*) FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try fixture.integer("SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 1)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "old note")
    }

    @Test
    func restoreUsesSameSelectorGrammarAndRestoresExistingTombstoneOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())

        _ = try AnnotationsDeleteCommand.parse(["123"]).execute(using: books)
        let restored = try AnnotationsRestoreCommand.parse(["123", "--sync"]).execute(using: books)
        #expect(restored.committed)
        #expect(restored.changed)
        #expect(restored.acknowledgementRequested)
        #expect(restored.acknowledged == false)
        #expect(restored.warningCodes == ["cloud_sync_failed"])
        #expect(restored.annotationUUID == "123")
        #expect(restored.annotationLocalPK == nil)
        #expect(try fixture.integer("SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=1") == 0)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "old note")

        let repeated = try AnnotationsRestoreCommand.parse(["--pk", "1", "--sync"]).execute(using: books)
        #expect(repeated.committed == false)
        #expect(repeated.changed == false)
        #expect(repeated.acknowledgementRequested)
        #expect(repeated.acknowledged == nil)

        try fixture.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1,ZANNOTATIONUUID=NULL WHERE Z_PK=1")
        let pkOnly = try AnnotationsRestoreCommand.parse(["--pk", "1"]).execute(using: books)
        #expect(pkOnly.committed)
        #expect(pkOnly.changed)
        #expect(pkOnly.annotationUUID == nil)
        #expect(pkOnly.annotationLocalPK == 1)

        let missing = try AnnotationsRestoreCommand.parse(["missing-uuid"])
        #expect(throws: CLIError.notFoundWithReason(
            message: "Annotation tombstone is unavailable.",
            reason: "annotation_restore_unavailable"
        )) {
            _ = try missing.execute(using: books)
        }
    }

    @Test
    func selectorConflictsFailBeforeAnyDatabaseConstruction() throws {
        for arguments in [
            ["123", "--pk", "1"],
            [],
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
        let restore = try AnnotationsRestoreCommand.parse(["123", "--pk", "1"])
        #expect(throws: ValidationError.self) {
            _ = try restore.execute(using: nil)
        }
    }

    @Test
    func coreOwnsNoteLengthAndDeletedSafetyRules() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books(controller: fixture.closedController())

        let empty = try AnnotationsUpdateNoteCommand.parse(["123"])
        #expect(throws: CLIError.usageInvalid("Annotation note length is invalid.")) {
            _ = try withInput("") { try empty.execute(using: books, input: $0) }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)

        let tooLong = try AnnotationsUpdateNoteCommand.parse(["123"])
        #expect(throws: CLIError.usageInvalid("Annotation note length is invalid.")) {
            _ = try withInput(String(repeating: "x", count: 10_001)) { try tooLong.execute(using: books, input: $0) }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)

        try fixture.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1 WHERE Z_PK=1")
        let deleted = try AnnotationsDeleteCommand.parse(["123"])
        let repeatedDelete = try deleted.execute(using: books)
        #expect(repeatedDelete.committed == false)
        #expect(repeatedDelete.changed == false)
        #expect(FileManager.default.fileExists(atPath: fixture.annotationBackupRoot.path) == false)

        try fixture.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=0,ZANNOTATIONTYPE=3 WHERE Z_PK=1")
        #expect(throws: CLIError.writeSafety("Annotation is not writable.")) {
            _ = try deleted.execute(using: books)
        }
        try fixture.execute("UPDATE ZAEANNOTATION SET ZANNOTATIONTYPE=NULL WHERE Z_PK=1")
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
        let command = try AnnotationsUpdateNoteCommand.parse(["123"])

        let result = try withInput("committed note") { try command.execute(using: books, input: $0) }

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.warningCodes == ["relaunch_failed"])
        #expect(terminateCount == 1)
        #expect(launchCount == 1)
        #expect(try fixture.text("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=1") == "committed note")
    }

    @Test
    func removedNoteOptionIsRejectedAndStreamingInputIsBoundedStrictUTF8() throws {
        #expect(throws: Error.self) {
            _ = try AnnotationsUpdateNoteCommand.parse(["123", "--note", "private"])
        }

        let boundary = Data(String(repeating: "🇯🇵", count: 8_192).utf8)
        #expect(boundary.count == AnnotationNoteInput.maximumUTF8Bytes)
        var boundaryOffset = 0
        let decoded = try AnnotationNoteInput.readBody { requested in
            guard boundaryOffset < boundary.count else { return Data() }
            let end = min(boundaryOffset + requested, boundary.count)
            defer { boundaryOffset = end }
            return boundary[boundaryOffset..<end]
        }
        #expect(decoded.utf8.count == AnnotationNoteInput.maximumUTF8Bytes)

        let oversized = Data(repeating: 0x61, count: AnnotationNoteInput.maximumUTF8Bytes * 4)
        var oversizedOffset = 0
        #expect(throws: CLIError.usageInvalid("Annotation note stdin exceeds 64 KiB.")) {
            _ = try AnnotationNoteInput.readBody { requested in
                let end = min(oversizedOffset + requested, oversized.count)
                defer { oversizedOffset = end }
                return oversized[oversizedOffset..<end]
            }
        }
        #expect(oversizedOffset == AnnotationNoteInput.maximumUTF8Bytes + 1)

        var invalidRead = false
        #expect(throws: CLIError.usageInvalid("Annotation note stdin must be valid UTF-8.")) {
            _ = try AnnotationNoteInput.readBody { _ in
                if invalidRead { return Data() }
                invalidRead = true
                return Data([0xFF])
            }
        }
    }

    private func withInput<T>(_ text: String, _ body: (FileHandle) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
        return try body(handle)
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
                  ZANNOTATIONTYPE INTEGER,
                  ZANNOTATIONUUID TEXT,
                  ZANNOTATIONNOTE TEXT,
                  ZANNOTATIONMODIFICATIONDATE REAL,
                  ZFUTUREPROOFING6 TEXT
                );
                INSERT INTO ZAEANNOTATION VALUES(1,17,3,0,2,'123','old note',1,'1');
                INSERT INTO ZAEANNOTATION VALUES(123,17,1,0,2,'other','other note',1,'1');
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

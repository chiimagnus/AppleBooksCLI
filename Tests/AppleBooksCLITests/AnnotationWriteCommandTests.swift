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
    func annotationMutationHelpExposesExplicitSyncFlagWithoutImplementationTerms() {
        for subcommand in ["update-note", "delete", "restore"] {
            var stdout = ""
            var stderr = ""
            let code = CLIEntrypoint.run(
                arguments: ["annotations", subcommand, "--help"],
                output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(stderr.isEmpty)
            let normalized = stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            #expect(stdout.contains("--sync"))
            #expect(normalized.contains("acknowledge this committed change on this Mac"))
            #expect(stdout.contains("CloudKit") == false)
            #expect(stdout.contains("projection") == false)
            #expect(stdout.contains("local-only") == false)
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
            reason: .annotationRestoreUnavailable
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
    func postCommitBooksStateRestoreFailureIsSuccessWithWarning() throws {
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
        #expect(result.warningCodes == ["books_state_restore_failed"])
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

    @Test
    func createAndPreviewAreReachableAndPreviewNeverEntersHistory() {
        var out = ""
        let result = CLIEntrypoint.run(
            arguments: ["annotations", "--help"],
            output: CLIOutput(stdout: { out += $0 }, stderr: { _ in })
        )
        #expect(result == CLIProcessExit.success.rawValue)
        #expect(out.contains("preview"))
        #expect(out.contains("create"))
    }

    @Test
    func createHistoryPinsInputBytesAndDoesNotEchoNotes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("annotations.json")
        let secret = "private synthetic note must not be in operation history"
        let payload = "{\"annotations\":[{\"text\":\"single token\",\"color\":\"green\",\"note\":\"" + secret + "\"}]}"
        try Data(payload.utf8).write(to: file)
        let args = ["--book", "synthetic-book", "--input", file.path]
        let command = try AnnotationsCreateCommand.parse(args)
        let history1 = try command.historyRequest()
        #expect(history1.selector?.bookAssetID == "synthetic-book")
        #expect(history1.inputDigest?.count == 64)
        #expect(history1.inputDigest == (try command.historyRequest()).inputDigest)
        let raw = String(decoding: try JSONEncoder().encode(history1), as: UTF8.self)
        #expect(raw.contains(secret) == false)
        #expect(raw.contains(file.path) == false)
        let changed = Data(#"{"annotations":[{"text":"another token","color":"green","note":"not the same file"}]}"#.utf8)
        try changed.write(to: file)
        // The parsed command and history must share the original immutable bytes.
        #expect(try command.historyRequest().inputDigest == history1.inputDigest)
        let other = try AnnotationsCreateCommand.parse(args)
        #expect(try other.historyRequest().inputDigest != history1.inputDigest)
        #expect(command.historyOperation == "annotations.create")
        try FileManager.default.removeItem(at: file)
        #expect(try command.historyRequest().inputDigest == history1.inputDigest)
    }

    @Test
    func boundedCreateInputRejectsInvalidSchemaAndSupportsReadOnlySymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.json")
        let link = root.appendingPathComponent("input-link.json")
        let accepted = #"{"annotations":[{"text":"private synthetic text","chapterOrder":2,"color":"purple","underline":true}]}"#
        try Data(accepted.utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let input = try AnnotationCreateInputCache().load(link.path)
        #expect(input.input.annotations.count == 1)
        #expect(input.input.annotations[0].nativeColor == .purple)
        #expect(input.input.annotations[0].isUnderlined == true)
        #expect(input.digest.count == 64)

        let invalid: [String] = [
            "", "not-json", #"{"annotations":[]}"#,
            #"{"annotations":[{"text":"x","rawCFI":"do not accept"}]}"#,
            #"{"annotations":[{"text":"x","color":"orange"}]}"#,
            #"{"annotations":[{"text":"x","occurrence":0}]}"#,
            #"{"annotations":[{"text":"x","note":"   "}]}"#,
            #"{"annotations":[{"text":1}]}"#,
            #"{"annotations":[{"text":"x"}],"private":true}"#,
            #"{"annotations":[{"text":"x","underline":"false"}]}"#,
        ]
        for value in invalid {
            try Data(value.utf8).write(to: file)
            #expect(throws: CLIError.self) { _ = try AnnotationCreateInputCache().load(file.path) }
        }
        let maximum = "{\"annotations\":["
            + Array(repeating: "{\"text\":\"sample\"}", count: 500).joined(separator: ",")
            + "]}"
        try Data(maximum.utf8).write(to: file)
        #expect(try AnnotationCreateInputCache().load(file.path).input.annotations.count == 500)
        let many = "{\"annotations\":["
            + Array(repeating: "{\"text\":\"sample\"}", count: 501).joined(separator: ",")
            + "]}"
        try Data(many.utf8).write(to: file)
        #expect(throws: CLIError.self) { _ = try AnnotationCreateInputCache().load(file.path) }
        let leading = "{\"annotations\":[{\"text\":\"small\",\"prefix\":\""
        let trailing = "\"}]}"
        let size = 8 * 1_024 * 1_024
        let exact = leading + String(repeating: "x", count: size - leading.utf8.count - trailing.utf8.count) + trailing
        let exactData = Data(exact.utf8)
        #expect(exactData.count == size)
        try exactData.write(to: file)
        #expect(try AnnotationCreateInputCache().load(file.path).input.annotations.count == 1)
        try Data(repeating: 0x20, count: size + 1).write(to: file)
        #expect(throws: CLIError.self) { _ = try AnnotationCreateInputCache().load(file.path) }
        try Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0x22, 0xFF, 0x22, 0x7D]).write(to: file)
        #expect(throws: CLIError.self) { _ = try AnnotationCreateInputCache().load(file.path) }
        try Data("{\"annotations\":[{\"text\":\"x\",\"note\":\"".utf8).write(to: file)
        #expect(throws: CLIError.self) { _ = try AnnotationCreateInputCache().load(file.path) }
    }

    @Test
    func previewAndSingleCreateShareCoreAndPersistOnlyOneSyntheticAnnotation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = root.appendingPathComponent("synthetic.epub")
        try FileManager.default.createDirectory(
            at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true
        )
        try Data("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
            <rootfiles><rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
            </rootfiles></container>
            """.utf8).write(to: epub.appendingPathComponent("META-INF/container.xml"))
        try Data("""
            <package xmlns="http://www.idpf.org/2007/opf"><metadata/><manifest>
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="chapter"/></spine></package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/content.opf"))
        try Data("""
            <html><head><title>Synthetic</title></head><body><p id="line1">Fresh synthetic test sentence.</p></body></html>
            """.utf8).write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))

        let library = root.appendingPathComponent("library.sqlite")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        func execute(_ database: URL, _ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
                throw CLIError.usageInvalid("Synthetic database setup failed.")
            }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw CLIError.usageInvalid("Synthetic database schema setup failed.")
            }
        }
        try execute(library, """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER,
              ZTITLE TEXT,ZAUTHOR TEXT
            );
            """)
        var libraryHandle: OpaquePointer?
        guard sqlite3_open(library.path, &libraryHandle) == SQLITE_OK, let libraryHandle else {
            throw CLIError.usageInvalid("Synthetic library unavailable.")
        }
        defer { sqlite3_close_v2(libraryHandle) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(libraryHandle,
              "INSERT INTO ZBKLIBRARYASSET VALUES(1,?,?,1,'Synthetic','Fixture')",
              -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CLIError.usageInvalid("Synthetic book preparation failed.")
        }
        defer { sqlite3_finalize(stmt) }
        guard bindSQLiteText("synthetic-asset", to: stmt, at: 1) == SQLITE_OK,
              bindSQLiteText(epub.path, to: stmt, at: 2) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE else {
            throw CLIError.usageInvalid("Synthetic book creation failed.")
        }
        try execute(annotations, """
            CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',17,0);
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONISUNDERLINE INTEGER,ZANNOTATIONSTYLE INTEGER,ZANNOTATIONTYPE INTEGER,
              ZPLABSOLUTEPHYSICALLOCATION INTEGER,ZPLLOCATIONRANGESTART INTEGER,
              ZPLLOCATIONRANGEEND INTEGER,ZANNOTATIONCREATIONDATE REAL,
              ZANNOTATIONMODIFICATIONDATE REAL,ZANNOTATIONASSETID TEXT,
              ZANNOTATIONCREATORIDENTIFIER TEXT,ZANNOTATIONLOCATION TEXT,
              ZANNOTATIONNOTE TEXT,ZANNOTATIONREPRESENTATIVETEXT TEXT,
              ZANNOTATIONSELECTEDTEXT TEXT,ZANNOTATIONUUID TEXT,
              ZFUTUREPROOFING11 TEXT,ZFUTUREPROOFING6 TEXT
            );
            """)
        let backupRoot = root.appendingPathComponent("backups")
        var projected: [Int64] = []
        let writer = AnnotationWriter(
            database: annotations, backupRoot: backupRoot, booksApp: .detached,
            creationProjector: AnnotationCloudProjector(projectAction: { projected.append($0) })
        )
        let books = try AppleBooks(
            libraryDB: library, annotationsDB: annotations, configurationFile: nil,
            collectionWriter: CollectionWriter(database: library, booksApp: .detached),
            annotationWriter: writer, libraryBackupRoot: backupRoot
        )
        let input = root.appendingPathComponent("notes.json")
        try Data("""
            {"annotations":[{"text":"synthetic","chapterOrder":1,"color":"green","note":"Synthetic note"}]}
            """.utf8).write(to: input)
        let args = ["--book", "synthetic-asset", "--input", input.path]
        let preview = try AnnotationsPreviewCommand.parse(args)
        let before = try preview.execute(using: books)
        #expect(before.complete && before.itemCount == 1)
        #expect(before.items[0].status == "ready")
        #expect(try executeScalar(annotations, "SELECT COUNT(*) FROM ZAEANNOTATION") == 0)
        #expect(!FileManager.default.fileExists(atPath: backupRoot.path))
        let create = try AnnotationsCreateCommand.parse(args)
        let inputHistory = try create.historyRequest()
        #expect(inputHistory.inputDigest?.count == 64)
        try Data("not JSON after the history was prepared".utf8).write(to: input)
        // Even after a file replacement, dispatch must consume the immutable history snapshot.
        let sink = OperationHistoryCompletionSink()
        let created = try create.execute(using: books, historySink: sink)
        #expect(created.changed)
        #expect(created.committed)
        #expect(sink.completion?.result.kind == .mutation)
        #expect(sink.completion?.inverse.available == true)
        #expect(projected == [1])
        #expect(try executeScalar(annotations, "SELECT COUNT(*) FROM ZAEANNOTATION") == 1)
        let after = try preview.execute(using: books)
        #expect(after.items[0].status == "already_exists")
        #expect(try create.historyRequest().inputDigest == inputHistory.inputDigest)
        let createdUUID = try #require(created.annotationUUID)
        let repair = try AnnotationsRepairSyncCommand.parse([createdUUID])
        #expect(try repair.historyRequest().selector?.annotationUUID == createdUUID)
        let repairSink = OperationHistoryCompletionSink()
        let repaired = try repair.execute(using: books, historySink: repairSink)
        #expect(repaired.verified)
        #expect(repaired.annotationUUID == createdUUID)
        #expect(repairSink.completion?.result.kind == .sync)
        #expect(repairSink.completion?.result.verified == true)
        #expect(repairSink.completion?.inverse.available == false)
        #expect(projected == [1, 1])
        #expect(try executeScalar(annotations, "SELECT COUNT(*) FROM ZAEANNOTATION") == 1)
        #expect(after.items[0].existingUUID == created.annotationUUID)
        try Data("""
            {"annotations":[
              {"text":"synthetic","chapterOrder":1,"color":"green","note":"Synthetic note"},
              {"text":"not in this chapter","chapterOrder":1},
              {"text":"synthetic","chapterOrder":1,"color":"blue","note":"Synthetic note"},
              {"text":"Fresh","chapterOrder":1},
              {"text":"e","chapterOrder":1},
              {"text":"Fresh","occurrence":1}
            ]}
            """.utf8).write(to: input)
        let mixedPreview = try AnnotationsPreviewCommand.parse(args).execute(using: books)
        #expect(!mixedPreview.complete)
        #expect(mixedPreview.status == "needs_review")
        #expect(mixedPreview.itemCount == 6)
        #expect(mixedPreview.items.map(\.status) == [
            "already_exists", "missing", "conflict", "ready", "ambiguous", "invalid"
        ])
        #expect(mixedPreview.items[4].candidateCount ?? 0 > 1)
        #expect(mixedPreview.items[4].recoveryHint != nil)
        #expect(try executeScalar(annotations, "SELECT COUNT(*) FROM ZAEANNOTATION") == 1)
        let duplicate = try create.execute(using: books)
        #expect(!duplicate.changed)
        #expect(try executeScalar(annotations, "SELECT COUNT(*) FROM ZAEANNOTATION") == 1)
        #expect(projected == [1, 1])
    }

    private func executeScalar(_ database: URL, _ sql: String) throws -> Int64 {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { throw CLIError.usageInvalid("Synthetic query failed.") }
        let handle = try #require(statement.handle)
        return sqlite3_column_int64(handle, 0)
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

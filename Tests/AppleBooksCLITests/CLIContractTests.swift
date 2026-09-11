import AppKit
import ArgumentParser
import Foundation
import PDFKit
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("CLIContractTests")
struct CLIContractTests {
    @Test
    func publicLocalPKFallbackRejectsNonPositiveValuesBeforeDependencyDiscovery() throws {
        #expect(LocalPKPolicy.isEligible(-1) == false)
        #expect(LocalPKPolicy.isEligible(0) == false)
        #expect(LocalPKPolicy.isEligible(1))
        #expect(LocalPKPolicy.isEligible(Int64.max))
        #expect(try parseBookSelector(assetID: nil, localPK: Int64.max) == .localPK(Int64.max))
        #expect(try parseAnnotationSelector(uuid: nil, localPK: Int64.max) == .localPK(Int64.max))
        #expect(try parseCollectionSelector(collectionID: nil, localPK: Int64.max) == .localPK(Int64.max))

        let missing = "/definitely/missing/applebookscli-pk-preflight.sqlite"
        let globals = ["--library-db", missing, "--annotations-db", missing]
        let cases: [[String]] = [
            ["books", "get", "--pk", "0"],
            ["reading", "position", "--pk", "-1"],
            ["content", "metadata", "--pk", "0"],
            ["annotations", "get", "--pk", "-1"],
            ["annotations", "list", "--book-pk", "0"],
            ["collections", "get", "--pk", "0"],
            ["collections", "add-book", "--collection-pk", "-1", "--book-pk", "1"],
            ["collections", "add-book", "--collection", "550E8400-E29B-41D4-A716-446655440000", "--book-pk", "0"],
            ["pdf", "highlights", "--book-pk", "0"],
        ]

        for arguments in cases {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
            #expect(capture.stderr.contains("PDF worker") == false)
        }
    }

    @Test
    func processParseHelpAndVersionContractsDoNotDiscoverDatabases() throws {
        let harness = try ProcessHarness()
        defer { harness.remove() }
        let sentinel = "secret-value-DO-NOT-ECHO"

        let failure = try harness.run(["books", "list", "--definitely-unknown", sentinel])
        #expect(failure.status == CLIProcessExit.usageInvalid.rawValue)
        #expect(failure.stdout.isEmpty)
        #expect(failure.stderr.contains(sentinel) == false)
        #expect(failure.stderr.contains("definitely-unknown") == false)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(failure.stderr.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "Invalid command-line arguments.")
        #expect(envelope.error.reason == nil)
        #expect(envelope.error.recoveryHint == nil)

        let help = try harness.run(["--help"])
        #expect(help.status == 0)
        #expect(help.stderr.isEmpty)
        #expect(help.stdout.contains("USAGE:"))
        #expect(help.stdout.contains("export"))
        #expect(help.stdout.contains("backups"))
        #expect(help.stdout.contains("history"))

        let version = try harness.run(["--version"])
        #expect(version.status == 0)
        #expect(version.stderr.isEmpty)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "dev")
        #expect(FileManager.default.fileExists(atPath: harness.historyRoot.path) == false)
    }

    @Test
    func recordableCommandWhitelistIsExact() throws {
        let cases: [([String], String)] = [
            (["annotations", "update-note", "annotation-id"], "annotations.update-note"),
            (["annotations", "delete", "annotation-id"], "annotations.delete"),
            (["annotations", "restore", "annotation-id"], "annotations.restore"),
            (["collections", "create", "Shelf"], "collections.create"),
            (["collections", "rename", "collection-id", "--title", "Renamed"], "collections.rename"),
            (["collections", "delete", "collection-id"], "collections.delete"),
            (["collections", "add-book", "--collection", "collection-id", "--book", "asset-id"], "collections.add-book"),
            (["collections", "remove-book", "--collection", "collection-id", "--book", "asset-id"], "collections.remove-book"),
            (["backups", "restore", "library__20000101T000000Z__00000000-0000-4000-8000-000000000000.sqlite"], "backups.restore"),
            (["sync"], "sync"),
        ]

        for (arguments, operation) in cases {
            let command = try AppleBooksCLI.parseAsRoot(arguments)
            let recordable = try #require(command as? any OperationHistoryRecordable)
            #expect(recordable.historyOperation == operation)
        }

        for arguments in [
            ["books", "list"],
            ["export", "--format", "json", "--output", "/tmp/non-recordable-export.json"],
            ["backups", "list"],
            ["history", "list"],
            ["history", "get", "00000000-0000-4000-8000-000000000000"],
        ] {
            let command = try AppleBooksCLI.parseAsRoot(arguments)
            #expect((command as? any OperationHistoryRecordable) == nil)
        }
    }

    @Test
    func processHistoryReadsDefaultHomeWithoutAppleBooksDatabasesOrRecursiveRecording() throws {
        let harness = try ProcessHarness()
        defer { harness.remove() }
        let store = OperationHistoryStore(root: harness.historyRoot)
        let privateArgument = "process-private-note"
        let token = try store.begin(
            operation: "annotations.update-note",
            request: OperationHistoryRequest(
                selector: OperationHistorySelector(annotationUUID: "uuid"),
                noteAction: .set()
            )
        )
        try store.complete(
            token,
            exitCode: 0,
            completion: OperationHistoryCompletion(
                result: .unavailable,
                inverse: OperationHistoryInverse(
                    available: true,
                    operation: "annotations.update-note",
                    selector: OperationHistorySelector(annotationUUID: "uuid"),
                    noteAction: .set(privateArgument),
                    title: nil
                )
            )
        )

        let list = try harness.run(["history", "list"])
        #expect(list.status == 0)
        #expect(list.stderr.isEmpty)
        #expect(list.stdout.contains(privateArgument) == false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let listResult = try decoder.decode(HistoryListResult.self, from: Data(list.stdout.utf8))
        #expect(listResult.items.count == 1)
        #expect(listResult.items[0].id == token.id)

        let get = try harness.run(["history", "get", token.id])
        #expect(get.status == 0)
        #expect(get.stderr.isEmpty)
        let detail = try decoder.decode(HistoryDetailResult.self, from: Data(get.stdout.utf8))
        #expect(detail.id == token.id)
        #expect(detail.request.selector?.annotationUUID == "uuid")
        #expect(detail.inverse.noteAction?.text == privateArgument)
        #expect(detail.result == .unavailable)
        #expect(try store.listPage(limit: 100).items.count == 1)
    }

    @Test
    func processReadContractCoversDoctorBooksReadingContentAnnotationsAndCollections() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let doctor = try fixture.runJSON(["doctor"])
        #expect(doctor["status"] as? String == "partial")
        let doctorComponents = try #require(doctor["components"] as? [String: Any])
        let doctorCapabilities = try #require(doctor["capabilities"] as? [String: Any])
        #expect(doctorComponents["libraryDatabaseReady"] as? Bool == true)
        #expect(doctorComponents["annotationsDatabaseReady"] as? Bool == true)
        #expect(doctorComponents["cloudSyncReady"] as? Bool == false)
        #expect(doctorComponents["pdfWorkerReady"] as? Bool == true)
        #expect(doctorCapabilities["booksRead"] as? Bool == true)
        #expect(doctorCapabilities["annotationsRead"] as? Bool == true)
        #expect(doctorCapabilities["syncPrerequisites"] as? Bool == false)

        let list = try fixture.runJSON(["books", "list"])
        #expect(list["total"] as? Int == 3)
        let listedBooks = try #require(list["items"] as? [[String: Any]])
        #expect(Set(listedBooks.compactMap { $0["assetID"] as? String }) == ["asset-a", "asset-b", "asset-pdf"])

        let get = try fixture.runJSON(["books", "get", "asset-a"])
        #expect(get["assetID"] as? String == "asset-a")
        #expect(get["localPK"] == nil)

        let search = try fixture.runJSON(["books", "search", "Book A"])
        #expect(search["total"] as? Int == 1)

        let inProgress = try fixture.runJSON(["reading", "in-progress"])
        let inProgressItems = try #require(inProgress["items"] as? [[String: Any]])
        #expect(inProgressItems.contains { $0["assetID"] as? String == "asset-a" })

        let stats = try fixture.runJSON(["stats"])
        #expect(stats["totalBooks"] as? Int == 3)
        #expect(stats["totalUserAnnotations"] as? Int == 3)

        let position = try fixture.runJSON(["reading", "position", "asset-a"])
        #expect(position["chapterOrder"] as? Int == 1)
        #expect(position["chapterID"] == nil)
        #expect(position["source"] == nil)

        let metadata = try fixture.runJSON(["content", "metadata", "asset-a"])
        #expect(metadata["bookAssetID"] as? String == "asset-a")
        #expect(metadata["bookLocalPK"] == nil)
        #expect(metadata["title"] as? String == "Book A")
        #expect(metadata["author"] as? String == "Author A")
        #expect(metadata["contentSource"] as? String == "current")
        #expect(metadata["epub"] == nil)
        #expect(metadata["database"] == nil)
        #expect(metadata["enrichment"] == nil)

        let chapter = try fixture.runJSON([
            "content", "chapter", "--book", "asset-a", "--chapter", "1", "--max-chars", "12",
        ])
        #expect(chapter["chapterOrder"] as? Int == 1)
        #expect(chapter["bookAssetID"] as? String == "asset-a")
        #expect(chapter["bookLocalPK"] == nil)
        #expect((chapter["content"] as? String)?.isEmpty == false)

        let context = try fixture.runJSON([
            "annotations", "context", "uuid-a", "--before", "8", "--after", "8",
        ])
        #expect(context["uuid"] as? String == "uuid-a")
        #expect(context["matched"] as? String == "First & 😀")
        #expect(context["canonicalText"] == nil)
        #expect(context["presentationText"] == nil)

        let annotations = try fixture.runJSON(["annotations", "list", "--book", "asset-a"])
        let annotationItems = try #require(annotations["items"] as? [[String: Any]])
        #expect(Set(annotationItems.compactMap { $0["uuid"] as? String }) == ["uuid-a", "uuid-update"])

        let annotationSearch = try fixture.runJSON([
            "annotations", "list", "--text", "note alpha", "--text-field", "note",
        ])
        let searchItems = try #require(annotationSearch["items"] as? [[String: Any]])
        #expect(searchItems.count == 1)
        #expect(searchItems[0]["uuid"] as? String == "uuid-a")

        let annotationRange = try fixture.runJSON([
            "annotations", "list",
            "--created-after", "2001-01-01T00:01:30Z",
            "--created-before", "2001-01-01T00:02:30Z",
        ])
        #expect((annotationRange["items"] as? [[String: Any]])?.isEmpty == false)

        let collections = try fixture.runJSON(["collections", "list"])
        let collectionItems = try #require(collections["items"] as? [[String: Any]])
        #expect(collectionItems.contains { $0["collectionID"] as? String == ProcessFixture.shelfID })

        let collection = try fixture.runJSON(["collections", "get", ProcessFixture.shelfID])
        #expect(collection["collectionID"] as? String == ProcessFixture.shelfID)
        #expect(collection["localPK"] == nil)
        #expect(collection["canEditCollection"] as? Bool == true)
        #expect(collection["canEditMembership"] as? Bool == true)
        for internalKey in ["sortKey", "sortMode", "viewMode", "isPlaceholder", "lastModificationDate", "localModificationDate"] {
            #expect(collection[internalKey] == nil)
        }

        let collectionSearch = try fixture.runJSON(["collections", "search", "Shelf"])
        #expect((collectionSearch["items"] as? [[String: Any]])?.count == 1)

        let collectionBooks = try fixture.runJSON(["collections", "books", ProcessFixture.shelfID])
        let memberItems = try #require(collectionBooks["items"] as? [[String: Any]])
        #expect(memberItems.map { $0["assetID"] as? String } == ["asset-a"])
    }

    @Test
    func processWritesUseGuardedBackupsAndRestoreOnlyScratchDatabases() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let create = try fixture.runJSON(["collections", "create", "Black Box Shelf"])
        #expect(create["committed"] as? Bool == true)
        #expect(create["changed"] as? Bool == true)
        let restoreBackupID = try #require(create["backupID"] as? String)
        #expect(restoreBackupID.hasPrefix("abk1_"))
        #expect(restoreBackupID.utf8.count == 64)
        #expect(restoreBackupID.contains("library") == false)
        #expect(restoreBackupID.contains(".sqlite") == false)
        #expect(try fixture.scalarInt("SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Black Box Shelf'", database: fixture.library) == 1)

        let note = "black box replacement"
        let update = try fixture.runJSON([
            "annotations", "update-note", "uuid-update",
        ], stdin: Data(note.utf8))
        #expect(update["committed"] as? Bool == true)
        #expect(update["annotationUUID"] as? String == "uuid-update")
        #expect(update["annotationLocalPK"] == nil)
        #expect(update["appleBooksURL"] == nil)
        #expect(update["backupID"] == nil)
        #expect(update["stableID"] == nil)
        #expect(update["localPK"] == nil)
        #expect(try fixture.scalarText("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'", database: fixture.annotations) == note)
        let backupNames = try FileManager.default.contentsOfDirectory(atPath: fixture.backupRoot.path)
        #expect(backupNames.contains { $0.hasPrefix("annotations__") && $0.hasSuffix(".sqlite") })

        let backups = try fixture.runJSON(["backups", "list"])
        let backupItems = try #require(backups["items"] as? [[String: Any]])
        #expect(backupItems.contains { $0["backupID"] as? String == restoreBackupID })
        #expect(backupItems.allSatisfy { $0["handle"] == nil })

        let restore = try fixture.runJSON(["backups", "restore", restoreBackupID])
        #expect(restore["changed"] as? Bool == true)
        #expect(restore["verified"] as? Bool == true)
        #expect(restore["restoredFromBackupID"] as? String == restoreBackupID)
        let safetyBackupID = try #require(restore["safetyBackupID"] as? String)
        #expect(safetyBackupID != restoreBackupID)
        #expect(safetyBackupID.hasPrefix("abk1_"))
        #expect(safetyBackupID.utf8.count == 64)
        #expect(restore["restoredFromHandle"] == nil)
        #expect(restore["safetyBackupHandle"] == nil)
        #expect(try fixture.scalarInt("SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Black Box Shelf'", database: fixture.library) == 0)

        // ponytail: explicit DB overrides intentionally use a detached Books.app lifecycle; backup side effects prove
        // the executable still traverses the mutation coordinator instead of implementing direct CLI SQLite writes.
        #expect(fixture.harness.home.path.hasPrefix(fixture.harness.root.path + "/"))
        #expect(fixture.backupRoot.path.hasPrefix(fixture.harness.home.path))
    }

    @Test
    func processAnnotationRestoreReappearsInOrdinaryReadsAndMissingTombstoneHasStableReason() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let deleted = try fixture.run(["annotations", "delete", "uuid-update"] + fixture.globals)
        #expect(deleted.status == 0)
        #expect(deleted.stderr.isEmpty)
        #expect(try fixture.scalarInt(
            "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'",
            database: fixture.annotations
        ) == 1)

        let hidden = try fixture.run(["annotations", "get", "uuid-update"] + fixture.globals)
        #expect(hidden.status == CLIProcessExit.notFound.rawValue)

        let restored = try fixture.run(["annotations", "restore", "uuid-update"] + fixture.globals)
        #expect(restored.status == 0)
        #expect(restored.stderr.isEmpty)
        #expect(try fixture.scalarInt(
            "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'",
            database: fixture.annotations
        ) == 0)

        let visible = try fixture.run(["annotations", "get", "uuid-update"] + fixture.globals)
        #expect(visible.status == 0)
        #expect(visible.stderr.isEmpty)

        let missing = try fixture.run(["annotations", "restore", "missing-uuid"] + fixture.globals)
        #expect(missing.status == CLIProcessExit.notFound.rawValue)
        #expect(missing.stdout.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(missing.stderr.utf8))
        #expect(envelope.error.code == .notFound)
        #expect(envelope.error.reason == "annotation_restore_unavailable")

        let history = try fixture.harness.historyRecords()
        let deleteRecord = try #require(history.first { $0.operation == "annotations.delete" })
        #expect(deleteRecord.inverse.available)
        #expect(deleteRecord.inverse.operation == "annotations.restore")
        #expect(deleteRecord.inverse.selector?.annotationUUID == "uuid-update")
        let restoreRecords = history.filter { $0.operation == "annotations.restore" }
        let restoreRecord = try #require(restoreRecords.first { $0.status == .success })
        #expect(restoreRecord.inverse.available)
        #expect(restoreRecord.inverse.operation == "annotations.delete")
        #expect(restoreRecord.inverse.selector?.annotationUUID == "uuid-update")
        let missingRecord = try #require(restoreRecords.first { $0.status == .failure })
        #expect(missingRecord.result == .unavailable)
        #expect(missingRecord.inverse == .unavailable)
    }

    @Test
    func processPKOnlyAnnotationHistoryDoesNotClaimAutomaticInverseButExplicitRestoreStillWorks() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        try fixture.executeSQL(
            "UPDATE ZAEANNOTATION SET ZANNOTATIONUUID=NULL WHERE Z_PK=4",
            database: fixture.annotations
        )

        let deleted = try fixture.run(["annotations", "delete", "--pk", "4"] + fixture.globals)
        #expect(deleted.status == 0)
        #expect(try fixture.scalarInt(
            "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=4",
            database: fixture.annotations
        ) == 1)

        let deleteRecord = try #require(try fixture.harness.historyRecords().first {
            $0.operation == "annotations.delete" && $0.result?.changed == true
        })
        #expect(deleteRecord.request.selector?.annotationLocalPK == 4)
        #expect(deleteRecord.inverse.available == false)
        #expect(deleteRecord.inverse.operation == nil)
        #expect(deleteRecord.inverse.selector == nil)

        let restored = try fixture.run(["annotations", "restore", "--pk", "4"] + fixture.globals)
        #expect(restored.status == 0)
        #expect(try fixture.scalarInt(
            "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=4",
            database: fixture.annotations
        ) == 0)
    }

    @Test
    func processUpdateNoteHistoryCarriesTypedTransactionInverseAcrossSetClearAndNull() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let originalValue = try fixture.scalarText(
            "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'",
            database: fixture.annotations
        )
        let original = try #require(originalValue)

        let replacement = "history replacement"
        let first = try fixture.run(
            ["annotations", "update-note", "uuid-update"] + fixture.globals,
            stdin: Data(replacement.utf8)
        )
        #expect(first.status == 0)
        let afterFirst = try fixture.harness.historyRecords()
        let firstRecord = try #require(afterFirst.first {
            $0.operation == "annotations.update-note"
        })
        #expect(firstRecord.request.noteAction?.kind == .set)
        #expect(firstRecord.request.noteAction?.text == nil)
        #expect(firstRecord.inverse.noteAction == .set(original))

        let clear = try fixture.run(
            ["annotations", "update-note", "uuid-update", "--clear"] + fixture.globals
        )
        #expect(clear.status == 0)
        let afterClear = try fixture.harness.historyRecords()
        let clearRecord = try #require(afterClear.first {
            $0.operation == "annotations.update-note" && $0.id != firstRecord.id
        })
        #expect(clearRecord.request.noteAction == .clear)
        #expect(clearRecord.inverse.noteAction == .set(replacement))

        let afterNull = "after null"
        let third = try fixture.run(
            ["annotations", "update-note", "uuid-update"] + fixture.globals,
            stdin: Data(afterNull.utf8)
        )
        #expect(third.status == 0)
        let afterThird = try fixture.harness.historyRecords()
        let thirdRecord = try #require(afterThird.first {
            $0.operation == "annotations.update-note"
                && $0.id != firstRecord.id
                && $0.id != clearRecord.id
        })
        #expect(thirdRecord.inverse.noteAction == .clear)
    }

    @Test
    func processCollectionHistoryCarriesRenameAndMembershipInverses() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let previousTitleValue = try fixture.scalarText(
            "SELECT ZTITLE FROM ZBKCOLLECTION WHERE ZCOLLECTIONID='\(ProcessFixture.shelfID)'",
            database: fixture.library
        )
        let previousTitle = try #require(previousTitleValue)

        let renamed = try fixture.run([
            "collections", "rename", ProcessFixture.shelfID, "--title", "History Renamed",
        ] + fixture.globals)
        #expect(renamed.status == 0)
        let afterRename = try fixture.harness.historyRecords()
        let renameRecord = try #require(afterRename.first {
            $0.operation == "collections.rename" && $0.status == .success
        })
        #expect(renameRecord.inverse.available)
        #expect(renameRecord.inverse.operation == "collections.rename")
        #expect(renameRecord.inverse.selector?.collectionID == ProcessFixture.shelfID)
        #expect(renameRecord.inverse.title == previousTitle)

        let removed = try fixture.run([
            "collections", "remove-book", "--collection", ProcessFixture.shelfID, "--book", "asset-a",
        ] + fixture.globals)
        #expect(removed.status == 0)
        let afterRemove = try fixture.harness.historyRecords()
        let removeRecord = try #require(afterRemove.first {
            $0.operation == "collections.remove-book"
        })
        #expect(removeRecord.result?.changed == true)
        #expect(removeRecord.inverse.operation == "collections.add-book")
        #expect(removeRecord.inverse.selector?.collectionID == ProcessFixture.shelfID)
        #expect(removeRecord.inverse.selector?.bookAssetID == "asset-a")

        let added = try fixture.run([
            "collections", "add-book", "--collection", ProcessFixture.shelfID, "--book", "asset-a",
        ] + fixture.globals)
        #expect(added.status == 0)
        let afterAdd = try fixture.harness.historyRecords()
        let addRecord = try #require(afterAdd.first {
            $0.operation == "collections.add-book"
        })
        #expect(addRecord.result?.changed == true)
        #expect(addRecord.inverse.operation == "collections.remove-book")
        #expect(addRecord.inverse.selector?.collectionID == ProcessFixture.shelfID)
        #expect(addRecord.inverse.selector?.bookAssetID == "asset-a")
    }

    @Test
    func processMutationOutputDefaultsToJSONAndNeverEchoesPrivateBody() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let privateNote = "synthetic private note"
        let annotation = try fixture.run([
            "annotations", "update-note", "uuid-update", "--sync",
        ] + fixture.globals, stdin: Data(privateNote.utf8))

        #expect(annotation.status == 0)
        #expect(annotation.stderr.isEmpty)
        #expect(annotation.stdout.contains(privateNote) == false)
        let annotationData = Data(annotation.stdout.utf8)
        let annotationResult = try JSONDecoder().decode(
            AnnotationMutationCommandResult.self,
            from: annotationData
        )
        #expect(annotationResult.committed)
        #expect(annotationResult.changed)
        #expect(annotationResult.annotationUUID == "uuid-update")
        #expect(annotationResult.annotationLocalPK == nil)
        #expect(annotationResult.warningCodes == ["cloud_sync_failed"])
        let annotationObject = try #require(JSONSerialization.jsonObject(with: annotationData) as? [String: Any])
        #expect(annotationObject["backupID"] == nil)
        #expect(annotationObject["appleBooksURL"] == nil)
        #expect(annotationObject["stableID"] == nil)
        #expect(annotationObject["localPK"] == nil)

        let noOp = try fixture.run([
            "collections", "add-book", "--collection", ProcessFixture.shelfID, "--book", "asset-a", "--sync",
        ] + fixture.globals)
        #expect(noOp.status == 0)
        #expect(noOp.stderr.isEmpty)
        let noOpResult = try JSONDecoder().decode(
            MembershipMutationCommandResult.self,
            from: Data(noOp.stdout.utf8)
        )
        #expect(noOpResult.changed == false)
        #expect(noOpResult.collectionID == ProcessFixture.shelfID)
        #expect(noOpResult.collectionLocalPK == nil)
        #expect(noOpResult.bookAssetID == "asset-a")
        #expect(noOpResult.bookLocalPK == nil)
        #expect(noOpResult.warningCodes.isEmpty)
    }

    @Test
    func processUpdateNoteUsesBoundedStdinAndExplicitClear() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }
        let base = ["annotations", "update-note", "uuid-update"] + fixture.globals

        let multiline = "line one\nline two\n"
        let set = try fixture.run(base, stdin: Data(multiline.utf8))
        #expect(set.status == 0)
        #expect(try fixture.scalarText("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'", database: fixture.annotations) == multiline)

        let identical = try fixture.run(base + ["--sync"], stdin: Data(multiline.utf8))
        let identicalResult = try JSONDecoder().decode(AnnotationMutationCommandResult.self, from: Data(identical.stdout.utf8))
        #expect(identicalResult.committed == false)
        #expect(identicalResult.changed == false)
        #expect(identicalResult.acknowledgementRequested)
        #expect(identicalResult.acknowledged == nil)

        let clear = try fixture.run(base + ["--clear"])
        #expect(clear.status == 0)
        #expect(try fixture.scalarInt("SELECT ZANNOTATIONNOTE IS NULL FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'", database: fixture.annotations) == 1)
        let clearAgain = try fixture.run(base + ["--clear", "--sync"])
        let clearAgainResult = try JSONDecoder().decode(AnnotationMutationCommandResult.self, from: Data(clearAgain.stdout.utf8))
        #expect(clearAgainResult.changed == false)
        #expect(clearAgainResult.acknowledgementRequested)
        #expect(clearAgainResult.acknowledged == nil)

        let conflict = try fixture.run(base + ["--clear"], stdin: Data("unexpected".utf8))
        #expect(conflict.status == CLIProcessExit.usageInvalid.rawValue)
        #expect(conflict.stdout.isEmpty)

        for invalid in ["", " \t\r\n"] {
            let rejected = try fixture.run(base, stdin: Data(invalid.utf8))
            #expect(rejected.status == CLIProcessExit.usageInvalid.rawValue)
            #expect(rejected.stdout.isEmpty)
        }

        let tenThousand = String(repeating: "x", count: 10_000)
        #expect(try fixture.run(base, stdin: Data(tenThousand.utf8)).status == 0)
        let tenThousandAndOne = String(repeating: "x", count: 10_001)
        #expect(try fixture.run(base, stdin: Data(tenThousandAndOne.utf8)).status == CLIProcessExit.usageInvalid.rawValue)

        let byteBoundary = String(repeating: "🇯🇵", count: 8_192)
        #expect(byteBoundary.count == 8_192)
        #expect(byteBoundary.utf8.count == 64 * 1_024)
        #expect(try fixture.run(base, stdin: Data(byteBoundary.utf8)).status == 0)
        let byteOverflow = byteBoundary + "🇯🇵"
        #expect(try fixture.run(base, stdin: Data(byteOverflow.utf8)).status == CLIProcessExit.usageInvalid.rawValue)

        let invalidUTF8 = try fixture.run(base, stdin: Data([0xFF]))
        #expect(invalidUTF8.status == CLIProcessExit.usageInvalid.rawValue)
        #expect(invalidUTF8.stdout.isEmpty)

        let embeddedNUL = "before\0after"
        #expect(try fixture.run(base, stdin: Data(embeddedNUL.utf8)).status == 0)
        #expect(try fixture.scalarText("SELECT hex(ZANNOTATIONNOTE) FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'", database: fixture.annotations) == "6265666F7265006166746572")
    }

    @Test
    func processRecordableCommandsPersistStructuredRequestsResultsAndInverses() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let createArguments = ["collections", "create", "History Shelf"] + fixture.globals
        let create = try fixture.run(createArguments)
        #expect(create.status == 0)
        #expect(create.stderr.isEmpty)
        #expect(try dictionary(create.stdout)["committed"] as? Bool == true)

        let privateNote = "history synthetic private note"
        let updateArguments = [
            "annotations", "update-note", "uuid-update",
        ] + fixture.globals
        let update = try fixture.run(updateArguments, stdin: Data(privateNote.utf8))
        #expect(update.status == 0)
        #expect(update.stderr.isEmpty)
        #expect(update.stdout.contains(privateNote) == false)
        #expect(try fixture.scalarText(
            "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'",
            database: fixture.annotations
        ) == privateNote)

        let noOpArguments = [
            "collections", "add-book", "--collection", ProcessFixture.shelfID, "--book", "asset-a",
        ] + fixture.globals
        let noOp = try fixture.run(noOpArguments)
        #expect(noOp.status == 0)
        #expect(try dictionary(noOp.stdout)["changed"] as? Bool == false)

        let renameFailureArguments = [
            "collections", "rename", "missing-collection", "--title", "Nope",
        ] + fixture.globals
        let renameFailure = try fixture.run(renameFailureArguments)
        #expect(renameFailure.status == CLIProcessExit.notFound.rawValue)
        #expect(renameFailure.stdout.isEmpty)
        let renameEnvelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(renameFailure.stderr.utf8))
        #expect(renameEnvelope.error.code == .notFound)

        let deleteFailureArguments = [
            "collections", "delete", "missing-collection",
        ] + fixture.globals
        let deleteFailure = try fixture.run(deleteFailureArguments)
        #expect(deleteFailure.status == CLIProcessExit.notFound.rawValue)
        #expect(deleteFailure.stdout.isEmpty)
        let deleteEnvelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(deleteFailure.stderr.utf8))
        #expect(deleteEnvelope.error.code == .notFound)

        let history = try fixture.harness.historyRecords()
        #expect(history.count == 5)

        let createRecord = try #require(history.first { $0.operation == "collections.create" })
        #expect(createRecord.status == .success)
        #expect(createRecord.request.title == "History Shelf")
        #expect(createRecord.result?.kind == .mutation)
        #expect(createRecord.result?.committed == true)
        #expect(createRecord.result?.changed == true)
        #expect(createRecord.inverse == .unavailable)

        let updateRecord = try #require(history.first { $0.operation == "annotations.update-note" })
        #expect(updateRecord.status == .success)
        #expect(updateRecord.request.selector?.annotationUUID == "uuid-update")
        #expect(updateRecord.request.noteAction?.kind == .set)
        #expect(updateRecord.request.noteAction?.text == nil)
        #expect(updateRecord.result?.kind == .mutation)
        #expect(updateRecord.inverse.available)
        #expect(updateRecord.inverse.operation == "annotations.update-note")
        #expect(updateRecord.inverse.selector?.annotationUUID == "uuid-update")
        #expect(updateRecord.inverse.noteAction != nil)

        let noOpRecord = try #require(history.first { $0.operation == "collections.add-book" })
        #expect(noOpRecord.status == .success)
        #expect(noOpRecord.request.selector?.collectionID == ProcessFixture.shelfID)
        #expect(noOpRecord.request.selector?.bookAssetID == "asset-a")
        #expect(noOpRecord.result?.committed == false)
        #expect(noOpRecord.result?.changed == false)
        #expect(noOpRecord.inverse == .unavailable)

        let renameFailureRecord = try #require(history.first { $0.operation == "collections.rename" })
        #expect(renameFailureRecord.status == .failure)
        #expect(renameFailureRecord.exitCode == CLIProcessExit.notFound.rawValue)
        #expect(renameFailureRecord.request.selector?.collectionID == "missing-collection")
        #expect(renameFailureRecord.request.title == "Nope")
        #expect(renameFailureRecord.result == .unavailable)
        #expect(renameFailureRecord.inverse == .unavailable)

        let deleteFailureRecord = try #require(history.first { $0.operation == "collections.delete" })
        #expect(deleteFailureRecord.status == .failure)
        #expect(deleteFailureRecord.exitCode == CLIProcessExit.notFound.rawValue)
        #expect(deleteFailureRecord.request.selector?.collectionID == "missing-collection")
        #expect(deleteFailureRecord.result == .unavailable)
        #expect(deleteFailureRecord.inverse == .unavailable)
    }

    @Test
    func historyBeginFailureBlocksRecordableCommandBeforeDatabaseDiscovery() throws {
        let harness = try ProcessHarness()
        defer { harness.remove() }
        try FileManager.default.createDirectory(
            at: harness.historyRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: harness.historyRoot)

        let invocation = try harness.run(["sync"])
        #expect(invocation.status == CLIProcessExit.unavailable.rawValue)
        #expect(invocation.stdout.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(invocation.stderr.utf8))
        #expect(envelope.error.code == .unavailable)
        #expect(envelope.error.message == "Operation history is unavailable.")
    }

    @Test
    func historyCompletionFailurePreservesSuccessfulOutcomeAndEmitsOneDiagnosticLine() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-history-completion-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("history", isDirectory: true)
        let fixed = try #require(ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z"))
        let store = OperationHistoryStore(
            root: root,
            now: { fixed },
            timeZone: { TimeZone(secondsFromGMT: 0)! }
        )

        var stdout = ""
        var stderr = ""
        var sabotageError: Error?
        var sabotaged = false
        let output = CLIOutput(
            stdout: { text in
                stdout += text
                guard sabotaged == false else { return }
                sabotaged = true
                do {
                    let lock = root.appendingPathComponent(".lock")
                    try FileManager.default.removeItem(at: lock)
                    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                } catch {
                    sabotageError = error
                }
            },
            stderr: { text in stderr += text }
        )

        let code = CLIEntrypoint.runParsed(
            HistorySuccessCommand(),
            arguments: ["history-success-test"],
            output: output,
            historyStore: store
        )
        #expect(sabotageError == nil)
        #expect(code == CLIProcessExit.success.rawValue)
        let primary = try JSONDecoder().decode(HistorySuccessResult.self, from: Data(stdout.utf8))
        #expect(primary == HistorySuccessResult(ok: true))
        let diagnosticLines = stderr.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(diagnosticLines.count == 1)
        let diagnostic = try JSONDecoder().decode(CLIDiagnosticEnvelope.self, from: Data(diagnosticLines[0].utf8))
        #expect(diagnostic == .historyCompletionFailed)

        let lock = root.appendingPathComponent(".lock")
        try FileManager.default.removeItem(at: lock)
        let records = try store.listPage(limit: 100).items
        #expect(records.count == 1)
        #expect(records[0].operation == "test.success")
        #expect(records[0].status == .incomplete)
    }

    @Test
    func committedHistoryEffectSurvivesPresentationFailure() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-history-presentation-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("history", isDirectory: true)
        let fixed = try #require(ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z"))
        let store = OperationHistoryStore(
            root: root,
            now: { fixed },
            timeZone: { TimeZone(secondsFromGMT: 0)! }
        )
        let capture = Capture()

        let code = CLIEntrypoint.runParsed(
            HistoryCommittedPresentationFailureCommand(),
            arguments: ["history-presentation-failure-test"],
            output: capture.output,
            historyStore: store
        )

        #expect(code == CLIProcessExit.internal.rawValue)
        let record = try #require(try store.listPage(limit: 10).items.first)
        let detail = try #require(try store.get(id: record.id))
        #expect(detail.status == .failure)
        #expect(detail.result?.kind == .mutation)
        #expect(detail.result?.committed == true)
        #expect(detail.result?.changed == true)
        #expect(detail.inverse.available)
        #expect(detail.inverse.operation == "annotations.restore")
        #expect(detail.inverse.selector?.annotationUUID == "synthetic-history-uuid")
    }

    @Test
    func processPDFInventoryAndHighlightsUseRelativeInstalledWorker() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let inventory = try fixture.runJSON(["pdf", "list"])
        let items = try #require(inventory["items"] as? [[String: Any]])
        #expect(items.contains { item in
            item["bookAssetID"] as? String == "asset-pdf" && item["pdfSourceID"] == nil
        })

        let highlights = try fixture.runJSON(["pdf", "highlights", "--book", "asset-pdf"])
        #expect(highlights["bookAssetID"] as? String == "asset-pdf")
        #expect(highlights["pdfSourceID"] == nil)
        #expect(highlights["hasMore"] as? Bool == false)
        #expect(highlights.keys.contains("nextCursor"))
        #expect(highlights["nextCursor"] is NSNull)
        let rows = try #require(highlights["items"] as? [[String: Any]])
        #expect(rows.first?["note"] as? String == "black box pdf")
        for internalKey in ["bounds", "quadrilateralPoints", "pdfKitRGBA", "traversalIndex", "textSource"] {
            #expect(rows.first?[internalKey] == nil)
        }
    }

    @Test
    func processPagedResultsEncodeTerminalCursorAsExplicitNull() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        func expectTerminalCursor(_ result: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(result["hasMore"] as? Bool == false, sourceLocation: sourceLocation)
            #expect(result.keys.contains("nextCursor"), sourceLocation: sourceLocation)
            #expect(result["nextCursor"] is NSNull, sourceLocation: sourceLocation)
        }

        let firstBooksPage = try fixture.runJSON(["books", "list", "--limit", "1"])
        #expect(firstBooksPage["hasMore"] as? Bool == true)
        #expect(firstBooksPage["nextCursor"] is String)

        for arguments in [
            ["books", "list", "--limit", "100"],
            ["reading", "unstarted", "--limit", "100"],
            ["collections", "list", "--limit", "100"],
            ["annotations", "list", "--limit", "100"],
            ["pdf", "list", "--limit", "100"],
            ["content", "chapters", "--book", "asset-a", "--limit", "100"],
            ["content", "chapter", "--book", "asset-a", "--chapter", "1", "--max-chars", "16000"],
        ] {
            expectTerminalCursor(try fixture.runJSON(arguments))
        }

        let history = try fixture.run(["history", "list"])
        #expect(history.status == 0)
        #expect(history.stderr.isEmpty)
        expectTerminalCursor(try dictionary(history.stdout))
    }

    @Test
    func sourceBuildProcessDiscoversSiblingWorkerForDoctorAndPDFHighlights() throws {
        let fixture = try ProcessFixture(layout: .swiftPM)
        defer { fixture.remove() }

        let doctor = try fixture.runJSON(["doctor"])
        let components = try #require(doctor["components"] as? [String: Any])
        #expect(components["pdfWorkerReady"] as? Bool == true)

        let highlights = try fixture.runJSON(["pdf", "highlights", "--book", "asset-pdf"])
        #expect(highlights["bookAssetID"] as? String == "asset-pdf")
        let rows = try #require(highlights["items"] as? [[String: Any]])
        #expect(rows.first?["note"] as? String == "black box pdf")
    }

    @Test
    func processExportWritesNativePayloadsOnlyToExplicitFiles() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let jsonFile = fixture.root.appendingPathComponent("export.json")
        let json = try fixture.run([
            "export", "--format", "json", "--source", "epub", "--output", jsonFile.path,
        ] + fixture.globals)
        #expect(json.status == 0)
        #expect(json.stderr.isEmpty)
        let jsonResult = try JSONDecoder().decode(ExportRunResult.self, from: Data(json.stdout.utf8))
        #expect(jsonResult.destination == jsonFile.standardizedFileURL.path)
        #expect(jsonResult.disposition == .file)
        #expect(jsonResult.documentCount == 1)
        #expect(json.stdout.contains("\"groups\"") == false)
        let exportRoot = try dictionary(String(decoding: try Data(contentsOf: jsonFile), as: UTF8.self))
        let groups = try #require(exportRoot["groups"] as? [[String: Any]])
        #expect(groups.count == 2)

        let markdownFile = fixture.harness.cwd.appendingPathComponent("export-notes")
        let markdown = try fixture.run([
            "export", "--source", "epub", "--output", markdownFile.lastPathComponent,
        ] + fixture.globals)
        #expect(markdown.status == 0)
        #expect(markdown.stderr.isEmpty)
        let markdownResult = try JSONDecoder().decode(ExportRunResult.self, from: Data(markdown.stdout.utf8))
        #expect(markdownResult.destination == markdownFile.standardizedFileURL.path)
        #expect(markdownResult.disposition == .file)
        #expect(markdown.stdout.contains("First & 😀") == false)
        let markdownArtifact = String(decoding: try Data(contentsOf: markdownFile), as: UTF8.self)
        #expect(markdownArtifact.contains("First & 😀"))
    }
}

private struct HistorySuccessResult: Codable, Equatable {
    let ok: Bool
}

private struct HistorySuccessCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(commandName: "history-success-test")

    var historyOperation: String { "test.success" }

    func historyRequest() throws -> OperationHistoryRequest { .unavailable }

    mutating func run() throws {}

    func run(output: CLIOutput) throws {
        try output.writeJSON(HistorySuccessResult(ok: true))
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        sink.record(OperationHistoryCompletion(result: .unavailable, inverse: .unavailable))
        try output.writeJSON(HistorySuccessResult(ok: true))
    }
}

private enum HistoryPresentationFailure: Error {
    case expected
}

private struct ThrowingHistoryPresentation: Encodable {
    func encode(to encoder: Encoder) throws {
        throw HistoryPresentationFailure.expected
    }
}

private struct HistoryCommittedPresentationFailureCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(commandName: "history-presentation-failure-test")

    var historyOperation: String { "annotations.delete" }

    func historyRequest() throws -> OperationHistoryRequest {
        OperationHistoryRequest(selector: OperationHistorySelector(annotationUUID: "synthetic-history-uuid"))
    }

    mutating func run() throws {}

    func run(output: CLIOutput) throws {
        try output.writeJSON(ThrowingHistoryPresentation())
    }

    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        sink.record(OperationHistoryCompletion(
            result: OperationHistoryResult(
                kind: .mutation,
                committed: true,
                changed: true,
                acknowledgementRequested: false,
                acknowledged: nil,
                verified: nil,
                collectionPendingBefore: nil,
                annotationPendingBefore: nil,
                warningCodes: []
            ),
            inverse: OperationHistoryInverse(
                available: true,
                operation: "annotations.restore",
                selector: OperationHistorySelector(annotationUUID: "synthetic-history-uuid"),
                noteAction: nil,
                title: nil
            )
        ))
        try output.writeJSON(ThrowingHistoryPresentation())
    }
}

private func dictionary(_ text: String) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
    guard let dictionary = value as? [String: Any] else { throw ContractFixtureError.invalidJSON }
    return dictionary
}

private struct ProcessInvocation {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ProcessHarness {
    enum Layout {
        case installed
        case swiftPM
    }

    let root: URL
    let home: URL
    let cwd: URL
    let executable: URL

    var historyRoot: URL {
        home.appendingPathComponent("Library/Application Support/AppleBooksCLI/history", isDirectory: true)
    }

    init(layout: Layout = .installed) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-contract-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("cwd", isDirectory: true)
        for directory in [home, cwd] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let products = try Self.swiftPMProductDirectory()
        let sourceCLI = products.appendingPathComponent("applebookscli")
        let sourceWorker = products.appendingPathComponent("applebookscli-pdf-worker")
        guard FileManager.default.isExecutableFile(atPath: sourceCLI.path),
              FileManager.default.isExecutableFile(atPath: sourceWorker.path) else {
            throw ContractFixtureError.missingExecutable
        }

        switch layout {
        case .swiftPM:
            executable = sourceCLI
        case .installed:
            let install = root.appendingPathComponent("install", isDirectory: true)
            let bin = install.appendingPathComponent("bin", isDirectory: true)
            let libexec = install.appendingPathComponent("libexec/applebookscli", isDirectory: true)
            for directory in [bin, libexec] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            executable = bin.appendingPathComponent("applebookscli")
            try FileManager.default.copyItem(at: sourceCLI, to: executable)
            try FileManager.default.copyItem(
                at: sourceWorker,
                to: libexec.appendingPathComponent("applebookscli-pdf-worker")
            )
        }
    }

    private static func swiftPMProductDirectory() throws -> URL {
        let products = Bundle(for: ProcessHarness.self)
            .bundleURL
            .deletingLastPathComponent()
            .standardizedFileURL
        guard products.isFileURL else { throw ContractFixtureError.missingExecutable }
        return products
    }

    func run(_ arguments: [String], stdin: Data? = nil) throws -> ProcessInvocation {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }
        try process.run()
        if let stdin, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let err = try stderr.fileHandleForReading.readToEnd() ?? Data()
        return ProcessInvocation(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    func historyRecords() throws -> [OperationHistoryRecord] {
        let store = OperationHistoryStore(root: historyRoot)
        var result: [OperationHistoryRecord] = []
        var cursor: String?
        repeat {
            let page = try store.listPage(limit: 100, cursor: cursor)
            for summary in page.items {
                if let record = try store.get(id: summary.id) { result.append(record) }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ProcessFixture {
    static let shelfID = "550E8400-E29B-41D4-A716-446655440000"

    let harness: ProcessHarness
    let root: URL
    let library: URL
    let annotations: URL
    let config: URL
    let epub: URL
    let pdf: URL

    var backupRoot: URL {
        harness.home.appendingPathComponent("Library/Application Support/AppleBooksCLI/backups", isDirectory: true)
    }

    var globals: [String] {
        [
            "--library-db", library.path,
            "--annotations-db", annotations.path,
            "--config", config.path,
        ]
    }

    init(layout: ProcessHarness.Layout = .installed) throws {
        harness = try ProcessHarness(layout: layout)
        root = harness.root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        epub = root.appendingPathComponent("synthetic.epub", isDirectory: true)
        pdf = root.appendingPathComponent("synthetic.pdf")
        library = root.appendingPathComponent("library.sqlite")
        annotations = root.appendingPathComponent("annotations.sqlite")
        config = root.appendingPathComponent("config.json")

        try Self.makeEPUB(at: epub)
        try Self.makePDF(at: pdf)
        try Self.execute(library, sql: Self.librarySQL(epub: epub.path, pdf: pdf.path))
        try Self.execute(annotations, sql: Self.annotationSQL)
        try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
    }

    func run(_ arguments: [String], stdin: Data? = nil) throws -> ProcessInvocation {
        try harness.run(arguments, stdin: stdin)
    }

    func runJSON(_ arguments: [String], stdin: Data? = nil) throws -> [String: Any] {
        let invocation = try run(arguments + globals, stdin: stdin)
        #expect(invocation.status == 0)
        #expect(invocation.stderr.isEmpty)
        return try dictionary(invocation.stdout)
    }

    func executeSQL(_ sql: String, database: URL) throws {
        try Self.execute(database, sql: sql)
    }

    func scalarInt(_ sql: String, database: URL) throws -> Int64 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else { throw ContractFixtureError.sqlite }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ContractFixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContractFixtureError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarText(_ sql: String, database: URL) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else { throw ContractFixtureError.sqlite }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ContractFixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContractFixtureError.sqlite }
        guard let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    func remove() {
        harness.remove()
    }

    private static func makeEPUB(at root: URL) throws {
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let ops = root.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata>
            <dc:title>Synthetic EPUB</dc:title>
            <dc:creator>Fixture Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="shared" href="shared.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="shared"/></spine>
        </package>
        """.utf8).write(to: ops.appendingPathComponent("package.opf"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol><li><a href="shared.xhtml">One</a></li></ol></nav></body>
        </html>
        """.utf8).write(to: ops.appendingPathComponent("nav.xhtml"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Before First &amp; 😀 After.</p><p>Second section tail.</p></body></html>
        """.utf8).write(to: ops.appendingPathComponent("shared.xhtml"))
    }

    private static func makePDF(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw ContractFixtureError.pdf }
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 100, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        annotation.contents = "black box pdf"
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: url) else { throw ContractFixtureError.pdf }
    }

    private static func execute(_ database: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw ContractFixtureError.sqlite
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContractFixtureError.sqlite
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func librarySQL(epub: String, pdf: String) -> String {
        """
        CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES
          ('BKCollection',7,20),
          ('BKCollectionMember',8,100);

        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT,
          ZBOOKDESCRIPTION TEXT,
          ZEPUBID TEXT,
          ZGENRE TEXT,
          ZGENRES BLOB,
          ZCOMMENTS TEXT,
          ZLANGUAGE TEXT,
          ZYEAR INTEGER,
          ZCONTENTTYPE INTEGER,
          ZPAGECOUNT INTEGER,
          ZPATH TEXT,
          ZFILESIZE INTEGER,
          ZCOVERURL TEXT,
          ZISFINISHED INTEGER,
          ZREADINGPROGRESS REAL,
          ZDURATION REAL,
          ZCREATIONDATE REAL,
          ZMODIFICATIONDATE REAL,
          ZDATEFINISHED REAL,
          ZLASTOPENDATE REAL,
          ZPURCHASEDATE REAL,
          ZRELEASEDATE REAL,
          ZISEXPLICIT INTEGER,
          ZISLOCKED INTEGER,
          ZISEPHEMERAL INTEGER,
          ZISHIDDEN INTEGER,
          ZISSAMPLE INTEGER,
          ZISSTOREAUDIOBOOK INTEGER,
          ZRATING REAL
        );
        INSERT INTO ZBKLIBRARYASSET
          (Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZGENRE,ZLANGUAGE,ZCONTENTTYPE,ZPATH,ZISFINISHED,ZREADINGPROGRESS,ZDATEFINISHED,ZLASTOPENDATE)
        VALUES
          (1,'asset-a','Book A','Author A','Fiction','en',1,'\(escaped(epub))',0,0.5,NULL,300),
          (2,'asset-b','Book B','Author B','History','en',1,'\(escaped(epub))',1,1.0,400,200),
          (3,'asset-pdf','PDF Book','PDF Author','Reference','en',3,'\(escaped(pdf))',0,0.0,NULL,100);

        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          Z_ENT INTEGER,
          Z_OPT INTEGER,
          ZDELETEDFLAG INTEGER,
          ZHIDDEN INTEGER,
          ZPLACEHOLDER INTEGER,
          ZSORTKEY INTEGER,
          ZSORTMODE INTEGER,
          ZVIEWMODE INTEGER,
          ZLASTMODIFICATION REAL,
          ZLOCALMODDATE REAL,
          ZCOLLECTIONID TEXT,
          ZDETAILS TEXT,
          ZTITLE TEXT
        );
        INSERT INTO ZBKCOLLECTION VALUES
          (10,7,1,0,0,0,10000,6,NULL,1,1,'\(shelfID)',NULL,'Shelf'),
          (20,7,1,0,0,0,20000,6,NULL,1,1,'550E8400-E29B-41D4-A716-446655440001',NULL,'Other');

        CREATE TABLE ZBKCOLLECTIONMEMBER(
          Z_PK INTEGER PRIMARY KEY,
          Z_ENT INTEGER,
          Z_OPT INTEGER,
          ZSORTKEY INTEGER,
          ZASSET INTEGER,
          ZCOLLECTION INTEGER,
          ZLOCALMODDATE REAL,
          ZASSETID TEXT,
          ZTEMPORARYASSETID TEXT
        );
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES(100,8,1,10000,1,10,1,'asset-a',NULL);
        """
    }

    private static let annotationSQL = """
    CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
    INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',11,4);
    CREATE TABLE ZAEANNOTATION(
      Z_PK INTEGER PRIMARY KEY,
      Z_ENT INTEGER,
      Z_OPT INTEGER,
      ZANNOTATIONUUID TEXT,
      ZANNOTATIONASSETID TEXT,
      ZANNOTATIONDELETED INTEGER,
      ZANNOTATIONISUNDERLINE INTEGER,
      ZANNOTATIONSTYLE INTEGER,
      ZANNOTATIONTYPE INTEGER,
      ZANNOTATIONCREATIONDATE REAL,
      ZANNOTATIONMODIFICATIONDATE REAL,
      ZANNOTATIONSELECTEDTEXT TEXT,
      ZANNOTATIONREPRESENTATIVETEXT TEXT,
      ZANNOTATIONNOTE TEXT,
      ZANNOTATIONLOCATION TEXT,
      ZPLABSOLUTEPHYSICALLOCATION INTEGER,
      ZPLLOCATIONRANGESTART INTEGER,
      ZPLLOCATIONRANGEEND INTEGER,
      ZFUTUREPROOFING5 TEXT,
      ZFUTUREPROOFING6 TEXT
    );
    INSERT INTO ZAEANNOTATION VALUES
      (1,11,1,'uuid-a','asset-a',0,0,1,1,100,200,'First & 😀','First representative','note alpha','epubcfi(/6/2[shared]!/4/2,:0,:9)',1,2,3,'shared','200'),
      (2,11,1,'uuid-bookmark','asset-a',0,0,1,3,110,300,NULL,NULL,NULL,'epubcfi(/6/2[shared]!/4/2,:0,:0)',NULL,NULL,NULL,'shared','300'),
      (3,11,1,'uuid-b','asset-b',0,0,2,1,120,220,'Second section','Second representative','note beta','epubcfi(/6/2[shared]!/4/2,:0,:14)',4,5,6,'shared','220'),
      (4,11,1,'uuid-update','asset-a',0,0,3,1,130,230,'Update quote','Update representative','old note','epubcfi(/6/2[shared]!/4/2,:0,:6)',7,8,9,'shared','230');
    """
}

private final class Capture {
    var stdout = ""
    var stderr = ""

    var output: CLIOutput {
        CLIOutput(
            stdout: { [self] in stdout += $0 },
            stderr: { [self] in stderr += $0 }
        )
    }
}

private enum ContractFixtureError: Error {
    case invalidJSON
    case missingExecutable
    case pdf
    case sqlite
}

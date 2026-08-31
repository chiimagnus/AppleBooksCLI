import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("FeatureParityRegressionTests")
struct FeatureParityRegressionTests {
    @Test
    func capabilityInventoryCoversTheCompletePublicSurface() throws {
        let data = try Data(contentsOf: fixtureRoot().appendingPathComponent("capabilities.json"))
        let inventory = try JSONDecoder().decode(CapabilityInventory.self, from: data)
        let expected: Set<String> = [
            "list_collections",
            "list_collection_books",
            "get_collection",
            "list_books",
            "list_all_books",
            "get_book",
            "search_books",
            "list_annotations",
            "get_book_annotations",
            "get_annotation",
            "get_highlights_by_color",
            "search_highlighted_text",
            "search_notes",
            "full_text_search",
            "recent_annotations",
            "add_book_to_collection",
            "remove_book_from_collection",
            "create_collection",
            "delete_collection",
            "list_backups",
            "restore_backup",
            "update_annotation_note",
            "delete_annotation",
            "export_annotations_markdown",
        ]
        let actual = inventory.capabilities.map(\.id)

        #expect(inventory.revision == 1)
        #expect(Set(actual) == expected)
        #expect(Set(actual).count == actual.count)
        #expect(inventory.capabilities.allSatisfy { $0.owner.isEmpty == false })
        #expect(String(decoding: data, as: UTF8.self).contains("http://") == false)
        #expect(String(decoding: data, as: UTF8.self).contains("https://") == false)
    }

    @Test
    func readAndMarkdownSurfacePreservesExactAndFailClosedContracts() throws {
        let fixture = try Fixture(running: false)
        defer { fixture.remove() }
        let expected = try loadExpected()

        #expect(try fixture.books.book(assetID: expected.bookStableAssetID)?.localPK == expected.bookStableLocalPK)
        #expect(try fixture.books.book(localPK: expected.bookExplicitLocalPK)?.assetID == expected.bookExplicitLocalAssetID)
        #expect(try fixture.books.books(matching: "Ada").map(\.localPK) == expected.combinedSearchLocalPKs)
        #expect(try fixture.books.collection(collectionID: expected.collectionID)?.localPK == 10)

        let bookPage = try fixture.books.bookPage()
        #expect(bookPage.total == expected.bookPageTotal)
        #expect(bookPage.limit == 20)
        #expect(bookPage.offset == 0)

        #expect(try fixture.books.annotation(uuid: expected.annotationStableUUID)?.annotation.localPK == expected.annotationStableLocalPK)
        #expect(try fixture.books.annotation(localPK: expected.annotationExplicitLocalPK)?.annotation.uuid == "uuid-local-12")
        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try fixture.books.annotation(uuid: "dup")
        }

        let activeRaw = try fixture.books.annotationPage(scope: .activeRaw)
        #expect(activeRaw.total == expected.annotationPageTotal)
        #expect(activeRaw.limit == 50)
        #expect(activeRaw.items.contains { $0.annotation.type == 3 })
        #expect(activeRaw.items.contains { $0.annotation.type == nil })
        #expect(activeRaw.items.contains { $0.annotation.localPK == 104 } == false)

        let green = try fixture.books.annotationPage(colorName: "green", scope: .activeRaw)
        #expect(green.items.map { $0.annotation.localPK } == expected.greenPageLocalPKs)
        #expect(green.total == expected.greenPageLocalPKs.count)

        #expect(
            try fixture.books.recentlyModifiedAnnotations().map { $0.annotation.localPK }
                == expected.recentlyModifiedLocalPKs
        )
        #expect(try fixture.books.annotation(uuid: "uuid-deleted", scope: .activeRaw) == nil)
        #expect(try fixture.books.annotation(uuid: "uuid-unknown-delete", scope: .activeRaw) == nil)

        let markdown = try fixture.books.exportAnnotationsMarkdown()
        #expect(markdown.contains(expected.orphanMarkdownText))
        for excluded in expected.excludedMarkdownText {
            #expect(markdown.contains(excluded) == false)
        }
    }

    @Test
    func stableWritesLifecycleBackupAndRestoreShareOneSafetyContract() throws {
        let fixture = try Fixture(running: true)
        defer { fixture.remove() }
        let expected = try loadExpected()
        let restorePoint = try SQLiteBackup.create(source: fixture.library, backupRoot: fixture.backupRoot)

        let annotationBackupsBefore = try SQLiteBackup.list(
            source: fixture.annotations,
            backupRoot: fixture.backupRoot
        ).count
        #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
            _ = try fixture.books.updateAnnotationNote(uuid: "uuid-deleted", note: "must reject")
        }
        #expect(throws: AnnotationWriteError.annotationDeletedOrUnknown) {
            _ = try fixture.books.updateAnnotationNote(uuid: "uuid-unknown-delete", note: "must reject")
        }
        #expect(
            try SQLiteBackup.list(source: fixture.annotations, backupRoot: fixture.backupRoot).count
                == annotationBackupsBefore
        )

        let updated = try fixture.books.updateAnnotationNote(uuid: expected.updateUUID, note: "new note")
        #expect(updated.committed)
        #expect(updated.stableID == expected.updateUUID)
        #expect(try text(fixture.annotations, "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=107") == "new note")
        #expect(try integer(fixture.annotations, "SELECT Z_OPT FROM ZAEANNOTATION WHERE Z_PK=107") == 5)
        #expect(fixture.state.running)

        let deleted = try fixture.books.deleteAnnotation(uuid: expected.deleteUUID)
        #expect(deleted.committed)
        #expect(deleted.stableID == expected.deleteUUID)
        #expect(try integer(fixture.annotations, "SELECT ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=108") == 1)

        let added = try fixture.books.addBook(assetID: "asset-1", toCollectionID: expected.collectionID)
        #expect(added.committed)
        #expect(added.changed)
        #expect(added.stableID == expected.collectionID)
        #expect(
            try integer(
                fixture.library,
                "SELECT ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'"
            ) == 30_000
        )

        let removed = try fixture.books.removeBook(assetID: "asset-3", fromCollectionID: expected.collectionID)
        #expect(removed.committed)
        #expect(removed.changed)
        #expect(
            try integer(
                fixture.library,
                "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-3'"
            ) == 0
        )

        let catalog = try fixture.books.listLibraryBackups()
        #expect(catalog.contains { $0.handle == restorePoint.lastPathComponent })
        #expect(catalog.allSatisfy { $0.handle.contains("/") == false })

        fixture.state.events.removeAll()
        let restored = try fixture.books.restoreLibraryBackup(handle: restorePoint.lastPathComponent)
        #expect(restored.restoreApplied)
        #expect(restored.verified)
        #expect(restored.warnings.isEmpty)
        #expect(restored.restoredFromHandle == restorePoint.lastPathComponent)
        #expect(restored.safetyBackupHandle.contains("/") == false)
        #expect(fixture.state.running)
        assertOrdered(["terminate", "backup", "launch"], in: fixture.state.events)
        #expect(
            try integer(
                fixture.library,
                "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-1'"
            ) == 0
        )
        #expect(
            try integer(
                fixture.library,
                "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=10 AND ZASSETID='asset-3'"
            ) == 1
        )

        fixture.state.running = false
        fixture.state.events.removeAll()
        let restoredWhileClosed = try fixture.books.restoreLibraryBackup(handle: restorePoint.lastPathComponent)
        #expect(restoredWhileClosed.restoreApplied)
        #expect(restoredWhileClosed.verified)
        #expect(fixture.state.running == false)
        #expect(fixture.state.events.contains("backup"))
        #expect(fixture.state.events.contains("terminate") == false)
        #expect(fixture.state.events.contains("launch") == false)
    }

    @Test
    func irreversibleBoundariesReturnWarningsInsteadOfFalseFailures() throws {
        let fixture = try Fixture(running: false)
        defer { fixture.remove() }
        let restorePoint = try SQLiteBackup.create(source: fixture.library, backupRoot: fixture.backupRoot)

        let mutationCoordinator = MutationCoordinator(
            database: fixture.library,
            backupRoot: fixture.backupRoot,
            booksApp: fixture.state.controller()
        )
        let mutation = try mutationCoordinator.perform(
            preflight: { _ in },
            revalidate: { _ in },
            mutation: { _ in () },
            domainData: { _ in MutationDomainData(changed: false) },
            readBack: { _, _ in throw TestFailure.verification }
        )
        #expect(mutation.committed)
        #expect(mutation.changed == false)
        #expect(mutation.warnings == [.readBackFailed])

        let restoreCoordinator = MutationCoordinator(
            database: fixture.library,
            backupRoot: fixture.backupRoot,
            booksApp: fixture.state.controller(),
            restoreVerificationAction: { throw TestFailure.verification }
        )
        let restore = try restoreCoordinator.restoreLibrary(handle: restorePoint.lastPathComponent)
        #expect(restore.restoreApplied)
        #expect(restore.verified == false)
        #expect(restore.warnings == [.verificationFailed])
        #expect(restore.safetyBackupHandle.contains("/") == false)
    }

    private static func fixtureRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FeatureParity", isDirectory: true)
    }

    private func fixtureRoot() -> URL {
        Self.fixtureRoot()
    }

    private func loadExpected() throws -> ExpectedFixture {
        let data = try Data(contentsOf: fixtureRoot().appendingPathComponent("expected.json"))
        return try JSONDecoder().decode(ExpectedFixture.self, from: data)
    }

    private func integer(_ database: URL, _ sql: String) throws -> Int64 {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return 0 }
        return sqlite3_column_int64(statement.handle, 0)
    }

    private func text(_ database: URL, _ sql: String) throws -> String? {
        let connection = try SQLiteConnection.readOnly(path: database.path)
        defer { try? connection.close() }
        let statement = try connection.prepare(sql)
        guard try statement.step(),
              sqlite3_column_type(statement.handle, 0) == SQLITE_TEXT,
              let raw = sqlite3_column_text(statement.handle, 0) else { return nil }
        return String(cString: raw)
    }

    private func assertOrdered(_ required: [String], in events: [String]) {
        var cursor = events.startIndex
        for item in required {
            guard let index = events[cursor...].firstIndex(of: item) else {
                Issue.record("missing lifecycle event \(item); events=\(events)")
                return
            }
            cursor = events.index(after: index)
        }
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let backupRoot: URL
        let state: LifecycleState
        let books: AppleBooks

        init(running: Bool) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            backupRoot = root.appendingPathComponent("backups", isDirectory: true)
            state = LifecycleState(running: running)

            try Self.createDatabase(
                library,
                sqlURL: FeatureParityRegressionTests.fixtureRoot().appendingPathComponent("library.sql")
            )
            try Self.createDatabase(
                annotations,
                sqlURL: FeatureParityRegressionTests.fixtureRoot().appendingPathComponent("annotations.sql")
            )
            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)

            let controller = state.controller()
            let collectionWriter = CollectionWriter(
                database: library,
                backupRoot: backupRoot,
                booksApp: controller
            )
            let annotationWriter = AnnotationWriter(
                database: annotations,
                backupRoot: backupRoot,
                booksApp: controller
            )
            let restoreCoordinator = MutationCoordinator(
                database: library,
                backupRoot: backupRoot,
                booksApp: controller,
                backupAction: { [state, library, backupRoot] preserving in
                    state.events.append("backup")
                    #expect(state.running == false)
                    return try SQLiteBackup.create(
                        source: library,
                        backupRoot: backupRoot,
                        keep: SQLiteBackup.retentionCount,
                        preserving: preserving
                    )
                }
            )
            books = try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: collectionWriter,
                annotationWriter: annotationWriter,
                libraryBackupRoot: backupRoot,
                restoreCoordinator: restoreCoordinator
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func createDatabase(_ database: URL, sqlURL: URL) throws {
            let sql = try String(contentsOf: sqlURL, encoding: .utf8)
            var handle: OpaquePointer?
            let open = sqlite3_open(database.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw SQLiteError.current(operation: .open, code: open, handle: handle)
            }
            defer { sqlite3_close_v2(handle) }
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: result, handle: handle)
            }
        }
    }

    private final class LifecycleState {
        var running: Bool
        var events: [String] = []

        init(running: Bool) {
            self.running = running
        }

        func controller() -> BooksAppController {
            BooksAppController(
                isRunning: { [self] in
                    events.append("isRunning")
                    return running
                },
                terminate: { [self] in
                    events.append("terminate")
                    running = false
                    return true
                },
                launch: { [self] in
                    events.append("launch")
                    running = true
                },
                sleep: { _ in }
            )
        }
    }

    private struct CapabilityInventory: Decodable {
        let revision: Int
        let capabilities: [Capability]
    }

    private struct Capability: Decodable {
        let id: String
        let owner: String
    }

    private struct ExpectedFixture: Decodable {
        let bookStableAssetID: String
        let bookStableLocalPK: Int64
        let bookExplicitLocalPK: Int64
        let bookExplicitLocalAssetID: String
        let combinedSearchLocalPKs: [Int64]
        let bookPageTotal: Int
        let annotationPageTotal: Int
        let greenPageLocalPKs: [Int64]
        let recentlyModifiedLocalPKs: [Int64]
        let annotationStableUUID: String
        let annotationStableLocalPK: Int64
        let annotationExplicitLocalPK: Int64
        let collectionID: String
        let updateUUID: String
        let deleteUUID: String
        let orphanMarkdownText: String
        let excludedMarkdownText: [String]
    }

    private enum TestFailure: Error {
        case verification
    }
}

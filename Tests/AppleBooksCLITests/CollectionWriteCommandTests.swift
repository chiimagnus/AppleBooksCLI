import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("CollectionWriteCommandTests")
struct CollectionWriteCommandTests {
    @Test
    func collectionsHelpRegistersMutationSurface() {
        var stdout = ""
        var stderr = ""
        let code = CLIEntrypoint.run(
            arguments: ["collections", "--help"],
            output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(stderr.isEmpty)
        for name in ["create", "rename", "delete", "add-book", "remove-book"] {
            #expect(stdout.contains(name))
        }
    }

    @Test
    func collectionMutationHelpExposesExplicitCloudSyncFlag() {
        for subcommand in ["create", "rename", "delete", "add-book", "remove-book"] {
            var stdout = ""
            var stderr = ""
            let code = CLIEntrypoint.run(
                arguments: ["collections", subcommand, "--help"],
                output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(stderr.isEmpty)
            #expect(stdout.contains("--sync"))
            #expect(stdout.contains("CloudKit"))
        }
    }

    @Test
    func createSyncFlagPreservesCommittedMutationAndSurfacesMissingLiveSyncAsWarning() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try CollectionsCreateCommand.parse(["Synced Shelf", "--sync"])

        let result = try command.execute(using: fixture.books())

        #expect(result.committed)
        #expect(result.changed)
        #expect(result.warningCodes == ["cloud_sync_failed"])
    }

    @Test
    func renameSyncFlagPreservesCommittedMutationWhenLiveCloudRailIsUnavailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try CollectionsRenameCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "--title", "Synced Rename", "--sync",
        ])
        let result = try command.execute(using: fixture.books())
        #expect(result.committed)
        #expect(result.warningCodes == ["cloud_sync_failed"])
        #expect(try fixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=10") == "Synced Rename")
    }

    @Test
    func createAndRenameUseCoreMutationRailAndStableRenamePreservesIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books()

        let create = try CollectionsCreateCommand.parse(["  New Shelf  ", "--details", "private details"])
        let created = try create.execute(using: books)
        #expect(created.committed)
        #expect(created.changed)
        #expect(created.localPK == 41)
        #expect(created.stableID != nil)
        #expect(created.humanDescription.contains("private details") == false)
        #expect(try fixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=41") == "New Shelf")
        #expect(try fixture.integer("SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=41") == 50_000)

        let rename = try CollectionsRenameCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "--title", "Renamed",
        ])
        let renamed = try rename.execute(using: books)
        #expect(renamed.localPK == 10)
        #expect(renamed.stableID == "550E8400-E29B-41D4-A716-446655440000")
        #expect(try fixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=10") == "Renamed")
    }

    @Test
    func addBookSupportsAllIndependentStableAndExplicitPKSelectorCombinations() throws {
        let cases: [([String], Int64, String)] = [
            (["550E8400-E29B-41D4-A716-446655440000", "asset-1"], 10, "asset-1"),
            (["550E8400-E29B-41D4-A716-446655440000", "--book-pk", "1"], 10, "asset-1"),
            (["--collection-pk", "10", "asset-1"], 10, "asset-1"),
            (["--collection-pk", "10", "--book-pk", "1"], 10, "asset-1"),
        ]

        for (arguments, collectionPK, assetID) in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let command = try CollectionsAddBookCommand.parse(arguments)
            let result = try command.execute(using: fixture.books())
            #expect(result.committed)
            #expect(result.changed)
            #expect(result.localPK == collectionPK)
            #expect(try fixture.integer(
                "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=\(collectionPK) AND ZASSETID='\(assetID)'"
            ) == 1)
            #expect(try fixture.integer(
                "SELECT ZSORTKEY FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=\(collectionPK) AND ZASSETID='\(assetID)'"
            ) == 30_000)
        }
    }

    @Test
    func duplicateAddAndMissingRemoveRemainIdempotentChangedFalse() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books()
        let add = try CollectionsAddBookCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "asset-1",
        ])
        #expect(try add.execute(using: books).changed)
        #expect(try add.execute(using: books).changed == false)

        let remove = try CollectionsRemoveBookCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "asset-1",
        ])
        #expect(try remove.execute(using: books).changed)
        #expect(try remove.execute(using: books).changed == false)
    }

    @Test
    func deleteUsesStableOrExplicitPKAndCoreCleansMemberships() throws {
        let stableFixture = try Fixture()
        defer { stableFixture.remove() }
        let stable = try CollectionsDeleteCommand.parse(["550E8400-E29B-41D4-A716-446655440001"])
        let stableResult = try stable.execute(using: stableFixture.books())
        #expect(stableResult.localPK == 20)
        #expect(stableResult.stableID == "550E8400-E29B-41D4-A716-446655440001")
        #expect(try stableFixture.integer("SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=20") == 1)
        #expect(try stableFixture.integer("SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 0)

        let pkFixture = try Fixture()
        defer { pkFixture.remove() }
        let pk = try CollectionsDeleteCommand.parse(["--pk", "20"])
        let pkResult = try pk.execute(using: pkFixture.books())
        #expect(pkResult.localPK == 20)
        #expect(pkResult.stableID == nil)
    }

    @Test
    func numericLookingValuesNeverGuessPKAndSelectorConflictsFailBeforeDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books()

        let numericCollection = try CollectionsAddBookCommand.parse(["10", "asset-1"])
        #expect(throws: CLIError.notFound("Collection not found.")) {
            _ = try numericCollection.execute(using: books)
        }

        let numericBook = try CollectionsAddBookCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "1",
        ])
        #expect(throws: CLIError.notFound("Book not found.")) {
            _ = try numericBook.execute(using: books)
        }

        let conflictingCollection = try CollectionsAddBookCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "asset-1", "--collection-pk", "10",
        ])
        #expect(throws: ValidationError.self) {
            _ = try conflictingCollection.execute(using: nil)
        }

        let conflictingBook = try CollectionsAddBookCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "asset-1", "--book-pk", "1",
        ])
        #expect(throws: ValidationError.self) {
            _ = try conflictingBook.execute(using: nil)
        }
    }

    @Test
    func systemCollectionGuardRemainsCoreOwned() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try CollectionsAddBookCommand.parse(["Books_Collection_ID", "asset-1"])
        #expect(throws: CLIError.writeSafety("Collection mutation failed safely.")) {
            _ = try command.execute(using: fixture.books())
        }
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
        let backupRoot: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            backupRoot = root.appendingPathComponent("backups")

            let fixtureURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/CollectionWriteParity/library.sql")
            let sql = try String(contentsOf: fixtureURL, encoding: .utf8)
            try Self.execute(library, sql)
            try Self.execute(annotations, "CREATE TABLE placeholder(value INTEGER)")
            try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
        }

        func books() throws -> AppleBooks {
            let controller = BooksAppController(
                isRunning: { false },
                terminate: { true },
                launch: {},
                sleep: { _ in }
            )
            return try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(
                    database: library,
                    backupRoot: backupRoot,
                    booksApp: controller
                )
            )
        }

        func integer(_ sql: String) throws -> Int64 {
            let connection = try SQLiteConnection.readOnly(path: library.path)
            defer { try? connection.close() }
            let statement = try connection.prepare(sql)
            guard try statement.step() else { return 0 }
            return sqlite3_column_int64(statement.handle, 0)
        }

        func text(_ sql: String) throws -> String? {
            let connection = try SQLiteConnection.readOnly(path: library.path)
            defer { try? connection.close() }
            let statement = try connection.prepare(sql)
            guard try statement.step() else { return nil }
            guard let raw = sqlite3_column_text(statement.handle, 0) else { return nil }
            return String(cString: raw)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func execute(_ database: URL, _ sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }
    }

    private enum FixtureError: Error { case sqlite }
}

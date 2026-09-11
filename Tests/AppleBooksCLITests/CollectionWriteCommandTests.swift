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
    func collectionMutationHelpExposesExplicitCloudSyncFlagAndNamedMembershipSelectors() {
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
            #expect(stdout.contains("After local commit"))
            #expect(stdout.contains("current-Mac CloudKit"))
            #expect(stdout.contains("projection"))
            #expect(stdout.contains("local-only") == false)
            if subcommand == "add-book" || subcommand == "remove-book" {
                for selector in ["--collection", "--collection-pk", "--book", "--book-pk"] {
                    #expect(stdout.contains(selector))
                }
                #expect(stdout.contains("ARGUMENTS:") == false)
            }
        }
    }

    @Test
    func membershipSelectorGrammarRejectsMissingConflictsInvalidTokensAndLegacyPositionalsBeforeDatabaseDiscovery() {
        let missing = "/definitely/missing/applebookscli-membership-selector.sqlite"
        let globals = ["--library-db", missing, "--annotations-db", missing]
        let collectionID = "550E8400-E29B-41D4-A716-446655440000"
        let cases: [[String]] = [
            ["collections", "add-book"],
            ["collections", "add-book", "--collection", collectionID],
            ["collections", "add-book", "--book", "asset-1"],
            ["collections", "add-book", "--collection", collectionID, "--collection-pk", "10", "--book", "asset-1"],
            ["collections", "add-book", "--collection", collectionID, "--book", "asset-1", "--book-pk", "1"],
            ["collections", "add-book", "--collection", " bad ", "--book", "asset-1"],
            ["collections", "add-book", "--collection", collectionID, "--book", " bad "],
            ["collections", "add-book", collectionID, "asset-1"],
            ["collections", "remove-book", collectionID, "asset-1"],
        ]

        for arguments in cases {
            var stdout = ""
            var stderr = ""
            let code = CLIEntrypoint.run(
                arguments: arguments + globals,
                output: CLIOutput(stdout: { stdout += $0 }, stderr: { stderr += $0 })
            )
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(stdout.isEmpty)
            #expect(stderr.contains("Database override") == false)
            #expect(stderr.contains(missing) == false)
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

        let create = try CollectionsCreateCommand.parse(["  New Shelf  "])
        let created = try create.execute(using: books)
        #expect(created.committed)
        #expect(created.changed)
        #expect(created.collectionLocalPK == nil)
        #expect(created.collectionID != nil)
        #expect(created.backupID != nil)
        let createdData = try JSONEncoder().encode(created)
        let createdObject = try #require(JSONSerialization.jsonObject(with: createdData) as? [String: Any])
        #expect(createdObject["collectionID"] != nil)
        #expect(createdObject["backupID"] != nil)
        #expect(createdObject["stableID"] == nil)
        #expect(createdObject["localPK"] == nil)
        #expect(createdObject["appleBooksURL"] == nil)
        #expect(try fixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=41") == "New Shelf")
        #expect(try fixture.integer("SELECT ZSORTKEY FROM ZBKCOLLECTION WHERE Z_PK=41") == 50_000)
        #expect(try fixture.text("SELECT ZDETAILS FROM ZBKCOLLECTION WHERE Z_PK=41") == nil)
        #expect(throws: (any Error).self) {
            _ = try CollectionsCreateCommand.parse(["Shelf", "--details", "removed"])
        }

        let rename = try CollectionsRenameCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "--title", "Renamed",
        ])
        let renamed = try rename.execute(using: books)
        #expect(renamed.collectionLocalPK == nil)
        #expect(renamed.collectionID == "550E8400-E29B-41D4-A716-446655440000")
        #expect(try fixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=10") == "Renamed")
    }

    @Test
    func addBookSupportsAllIndependentStableAndExplicitPKSelectorCombinations() throws {
        let cases: [([String], Int64, String)] = [
            (["--collection", "550E8400-E29B-41D4-A716-446655440000", "--book", "asset-1"], 10, "asset-1"),
            (["--collection", "550E8400-E29B-41D4-A716-446655440000", "--book-pk", "1"], 10, "asset-1"),
            (["--collection-pk", "10", "--book", "asset-1"], 10, "asset-1"),
            (["--collection-pk", "10", "--book-pk", "1"], 10, "asset-1"),
        ]

        for (arguments, collectionPK, assetID) in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let command = try CollectionsAddBookCommand.parse(arguments)
            let result = try command.execute(using: fixture.books())
            #expect(result.committed)
            #expect(result.changed)
            #expect(result.collectionID == "550E8400-E29B-41D4-A716-446655440000")
            #expect(result.collectionLocalPK == nil)
            #expect(result.bookAssetID == assetID)
            #expect(result.bookLocalPK == nil)
            let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
            #expect(object["collectionID"] != nil)
            #expect(object["bookAssetID"] != nil)
            #expect(object["stableID"] == nil)
            #expect(object["localPK"] == nil)
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
            "--collection", "550E8400-E29B-41D4-A716-446655440000", "--book", "asset-1", "--sync",
        ])
        let firstAdd = try add.execute(using: books)
        #expect(firstAdd.changed)
        #expect(firstAdd.warningCodes == ["cloud_sync_failed"])
        let duplicateAdd = try add.execute(using: books)
        #expect(duplicateAdd.changed == false)
        #expect(duplicateAdd.warningCodes.isEmpty)

        let remove = try CollectionsRemoveBookCommand.parse([
            "--collection", "550E8400-E29B-41D4-A716-446655440000", "--book", "asset-1", "--sync",
        ])
        let firstRemove = try remove.execute(using: books)
        #expect(firstRemove.changed)
        #expect(firstRemove.warningCodes == ["cloud_sync_failed"])
        let missingRemove = try remove.execute(using: books)
        #expect(missingRemove.changed == false)
        #expect(missingRemove.warningCodes.isEmpty)
    }

    @Test
    func deleteUsesStableOrExplicitPKAndCoreCleansMemberships() throws {
        let stableFixture = try Fixture()
        defer { stableFixture.remove() }
        let stable = try CollectionsDeleteCommand.parse(["550E8400-E29B-41D4-A716-446655440001"])
        let stableResult = try stable.execute(using: stableFixture.books())
        #expect(stableResult.collectionLocalPK == nil)
        #expect(stableResult.collectionID == "550E8400-E29B-41D4-A716-446655440001")
        #expect(try stableFixture.integer("SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=20") == 1)
        #expect(try stableFixture.integer("SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=20") == 0)

        let pkFixture = try Fixture()
        defer { pkFixture.remove() }
        let pk = try CollectionsDeleteCommand.parse(["--pk", "20"])
        let pkResult = try pk.execute(using: pkFixture.books())
        #expect(pkResult.collectionID == "550E8400-E29B-41D4-A716-446655440001")
        #expect(pkResult.collectionLocalPK == nil)
    }

    @Test
    func numericLookingValuesNeverGuessPKAndSelectorConflictsFailBeforeDatabase() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.books()

        let numericCollection = try CollectionsAddBookCommand.parse([
            "--collection", "10", "--book", "asset-1",
        ])
        #expect(throws: CLIError.notFound("Collection not found.")) {
            _ = try numericCollection.execute(using: books)
        }

        let numericBook = try CollectionsAddBookCommand.parse([
            "--collection", "550E8400-E29B-41D4-A716-446655440000", "--book", "1",
        ])
        #expect(throws: CLIError.notFound("Book not found.")) {
            _ = try numericBook.execute(using: books)
        }

        let conflictingCollection = try CollectionsAddBookCommand.parse([
            "--collection", "550E8400-E29B-41D4-A716-446655440000", "--collection-pk", "10", "--book", "asset-1",
        ])
        #expect(throws: ValidationError.self) {
            _ = try conflictingCollection.execute(using: nil)
        }

        let conflictingBook = try CollectionsAddBookCommand.parse([
            "--collection", "550E8400-E29B-41D4-A716-446655440000", "--book", "asset-1", "--book-pk", "1",
        ])
        #expect(throws: ValidationError.self) {
            _ = try conflictingBook.execute(using: nil)
        }
    }

    @Test
    func collectionTitlesTrimAndEnforceMetadataInputBoundsBeforeBackup() throws {
        let valid = try Fixture()
        defer { valid.remove() }
        let books = try valid.books()

        let trimmed = try CollectionsCreateCommand.parse(["  Trimmed Shelf  \n"])
        _ = try trimmed.execute(using: books)
        #expect(try valid.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE ZTITLE='Trimmed Shelf'") == "Trimmed Shelf")

        let exactGraphemes = String(repeating: "a", count: 512)
        _ = try CollectionsCreateCommand.parse([exactGraphemes]).execute(using: books)
        #expect(try valid.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE ZTITLE='\(exactGraphemes)'") == exactGraphemes)

        let combiningCluster = "a" + String(repeating: "\u{0301}", count: 7)
        let exactUnicode = String(repeating: combiningCluster, count: 512)
        #expect(exactUnicode.count == 512)
        #expect(exactUnicode.utf8.count < 8 * 1_024)
        _ = try CollectionsCreateCommand.parse([exactUnicode]).execute(using: books)

        for invalidTitle in [
            " \t\r\n ",
            String(repeating: "a", count: 513),
            String(repeating: "a" + String(repeating: "\u{0301}", count: 8), count: 512),
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let command = try CollectionsCreateCommand.parse([invalidTitle])
            #expect(throws: CLIError.usageInvalid("Collection title must be non-empty and at most 512 characters / 8 KiB UTF-8 after trimming.")) {
                _ = try command.execute(using: fixture.books())
            }
            #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.path) == false)
        }

        let renameFixture = try Fixture()
        defer { renameFixture.remove() }
        let rename = try CollectionsRenameCommand.parse([
            "550E8400-E29B-41D4-A716-446655440000", "--title", "  Canonical Rename\n",
        ])
        _ = try rename.execute(using: renameFixture.books())
        #expect(try renameFixture.text("SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=10") == "Canonical Rename")
    }

    @Test
    func systemCollectionGuardRemainsCoreOwned() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try CollectionsAddBookCommand.parse([
            "--collection", "Books_Collection_ID", "--book", "asset-1",
        ])
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

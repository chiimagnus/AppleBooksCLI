import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("CollectionReadCommandTests")
struct CollectionReadCommandTests {
    @Test
    func collectionsHelpRegistersReadSurface() {
        let capture = Capture()
        let code = CLIEntrypoint.run(arguments: ["collections", "--help"], output: capture.output)
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("list"))
        #expect(capture.stdout.contains("get"))
        #expect(capture.stdout.contains("search"))
        #expect(capture.stdout.contains("books"))
    }

    @Test
    func listPreservesCanonicalMetadataAndExcludesDeletedStates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let page = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "list", "--limit", "2", "--offset", "1"]
        )

        #expect(page.items.map(\.localPK) == [1, 123])
        #expect(page.items[0].collectionID == "123")
        #expect(page.items[0].title == "Beta")
        #expect(page.items[0].details == "detail beta")
        #expect(page.items[0].isHidden == true)
        #expect(page.items.allSatisfy { $0.isDeleted == false })
        #expect(page.items.contains(where: { $0.localPK == 3 || $0.localPK == 4 }) == false)
    }

    @Test
    func getTreatsNumericBareValueAsExactCollectionIDAndPKOnlyWhenExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byID = try fixture.runJSON(CollectionResult.self, ["collections", "get", "123"])
        #expect(byID.localPK == 1)
        #expect(byID.collectionID == "123")

        let byPK = try fixture.runJSON(CollectionResult.self, ["collections", "get", "--pk", "123"])
        #expect(byPK.localPK == 123)
        #expect(byPK.collectionID == "other")

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["collections", "get", "123", "--pk", "1"] + Fixture.missingGlobals,
            output: capture.output
        )
        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.contains("Database override") == false)
    }

    @Test
    func searchUsesCoreLiteralSubstringAndPagination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let literal = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "search", "%_\\"]
        )
        #expect(literal.items.map(\.localPK) == [2])

        let page = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "search", "a", "--limit", "1", "--offset", "1"]
        )
        #expect(page.items.map(\.localPK) == [1])

        for arguments in [
            ["collections", "search", ""],
            ["collections", "search", "a", "--limit", "0"],
            ["collections", "list", "--offset", "-1"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + Fixture.missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.contains("Database override") == false)
        }
    }

    @Test
    func booksUsesCoreMembershipOrderStaleSkippingAndDeduplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byID = try fixture.runJSON(CollectionBooksResult.self, ["collections", "books", "123"])
        #expect(byID.items.map(\.localPK) == [11, 12, 10])

        let byPK = try fixture.runJSON(CollectionBooksResult.self, ["collections", "books", "--pk", "1"])
        #expect(byPK.items.map(\.localPK) == [11, 12, 10])
        #expect(byPK.items.map(\.assetID) == ["asset-b", "asset-b", "asset-a"])
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL

        static let missingGlobals = [
            "--library-db", "/definitely/missing/applebookscli-t12-library.sqlite",
            "--annotations-db", "/definitely/missing/applebookscli-t12-annotations.sqlite",
            "--json",
        ]

        var globals: [String] {
            ["--library-db", library.path, "--annotations-db", annotations.path]
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(library, sql: Self.librarySQL)
            try Self.createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globals + ["--json"], output: capture.output)
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            return try JSONDecoder().decode(type, from: Data(capture.stdout.utf8))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static let librarySQL = """
        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          ZCOLLECTIONID TEXT,
          ZTITLE TEXT,
          ZDETAILS TEXT,
          ZDELETEDFLAG INTEGER,
          ZHIDDEN INTEGER
        );
        CREATE TABLE ZBKCOLLECTIONMEMBER(
          Z_PK INTEGER PRIMARY KEY,
          ZCOLLECTION INTEGER,
          ZASSETID TEXT,
          ZSORTKEY REAL
        );
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT
        );
        INSERT INTO ZBKCOLLECTION VALUES
          (1,'123','Beta','detail beta',0,1),
          (2,'literal','Alpha %_\\','detail literal',0,0),
          (3,'deleted','Deleted','private',1,0),
          (4,'unknown','Unknown','private',NULL,0),
          (123,'other','Gamma',NULL,0,0);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (10,'asset-a','A','Ada'),
          (11,'asset-b','B','Bob'),
          (12,'asset-b','B duplicate','Bob');
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES
          (100,1,'asset-a',20),
          (101,1,'asset-b',10),
          (102,1,'missing-asset',15),
          (103,1,'asset-b',30),
          (104,1,NULL,5);
        """
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""
        var output: CLIOutput {
            CLIOutput(stdout: { [self] in stdout += $0 }, stderr: { [self] in stderr += $0 })
        }
    }

    private enum FixtureError: Error { case sqlite }
}

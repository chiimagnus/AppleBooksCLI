import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("BooksCommandTests")
struct BooksCommandTests {
    @Test
    func listDefaultsToContentPageAndAllUsesUnlimitedSurface() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let paged = Capture()
        let pagedCode = CLIEntrypoint.run(
            arguments: ["books", "list"] + fixture.globalArguments + ["--json"],
            output: paged.output
        )
        #expect(pagedCode == CLIProcessExit.success.rawValue)
        #expect(paged.stderr.isEmpty)
        let page = try decode(BookPageResult.self, paged.stdout)
        #expect(page.total == 3)
        #expect(page.limit == 20)
        #expect(page.offset == 0)
        #expect(page.items.contains(where: { $0.assetID == "null-content" }) == false)

        let unlimited = Capture()
        let unlimitedCode = CLIEntrypoint.run(
            arguments: ["books", "list", "--all"] + fixture.globalArguments + ["--json"],
            output: unlimited.output
        )
        #expect(unlimitedCode == CLIProcessExit.success.rawValue)
        let all = try decode(BookPageResult.self, unlimited.stdout)
        #expect(all.total == 4)
        #expect(all.limit == nil)
        #expect(all.items.contains(where: { $0.assetID == "null-content" }))
    }

    @Test
    func getKeepsExactAssetIdentitySeparateFromExplicitLocalPKAndReturnsRichJSON() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let assetCapture = Capture()
        let assetCode = CLIEntrypoint.run(
            arguments: ["books", "get", "12"] + fixture.globalArguments + ["--json"],
            output: assetCapture.output
        )
        #expect(assetCode == CLIProcessExit.success.rawValue)
        let asset = try decode(BookResult.self, assetCapture.stdout)
        #expect(asset.localPK == 1)
        #expect(asset.assetID == "12")
        #expect(asset.author == "Ada\u{E000} Author")
        #expect(asset.normalizedAuthor == "Ada Author")
        #expect(asset.description == "Alpha description")
        #expect(asset.epubID == "epub-alpha")
        #expect(asset.genresRaw == Data([0x01, 0x02]))
        #expect(asset.readingProgressRaw == 0.5)
        #expect(asset.readingProgressPercent == 50)
        #expect(asset.durationRawMilliseconds == 2_000)
        #expect(asset.durationSeconds == 2)
        #expect(asset.userAnnotationCount == 1)

        let pkCapture = Capture()
        let pkCode = CLIEntrypoint.run(
            arguments: ["books", "get", "--pk", "12"] + fixture.globalArguments + ["--json"],
            output: pkCapture.output
        )
        #expect(pkCode == CLIProcessExit.success.rawValue)
        let pk = try decode(BookResult.self, pkCapture.stdout)
        #expect(pk.localPK == 12)
        #expect(pk.assetID == "asset-pk-12")
    }

    @Test
    func missingGetUsesStableNotFoundErrorEnvelope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["books", "get", "missing"] + fixture.globalArguments + ["--json"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.notFound.rawValue)
        #expect(capture.stderr.isEmpty)
        let envelope = try decode(CLIErrorEnvelope.self, capture.stdout)
        #expect(envelope.error.code == .notFound)
        #expect(envelope.error.message == "Book not found.")
    }

    @Test
    func searchAndGenreReuseCoreLiteralSemanticsAndReportTrueTotals() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let searchCapture = Capture()
        let searchCode = CLIEntrypoint.run(
            arguments: ["books", "search", "a", "--limit", "1", "--offset", "1"] + fixture.globalArguments + ["--json"],
            output: searchCapture.output
        )
        #expect(searchCode == CLIProcessExit.success.rawValue)
        let search = try decode(BookPageResult.self, searchCapture.stdout)
        #expect(search.total == 4)
        #expect(search.limit == 1)
        #expect(search.offset == 1)
        #expect(search.items.count == 1)

        let genreCapture = Capture()
        let genreCode = CLIEntrypoint.run(
            arguments: ["books", "genre", "Fiction"] + fixture.globalArguments + ["--json"],
            output: genreCapture.output
        )
        #expect(genreCode == CLIProcessExit.success.rawValue)
        let genre = try decode(BookPageResult.self, genreCapture.stdout)
        #expect(genre.total == 2)
        #expect(genre.limit == nil)
        #expect(Set(genre.items.compactMap(\.assetID)) == ["12", "null-content"])
    }

    @Test
    func annotatedListUsesCanonicalUserAnnotationCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["books", "list", "--annotated"] + fixture.globalArguments + ["--json"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        let page = try decode(BookPageResult.self, capture.stdout)
        #expect(page.total == 2)
        #expect(page.limit == 20)
        let counts = Dictionary(uniqueKeysWithValues: page.items.compactMap { item in
            item.assetID.flatMap { assetID in item.userAnnotationCount.map { (assetID, $0) } }
        })
        #expect(counts == ["12": 1, "history-id": 1])
    }

    @Test
    func invalidSelectorAndPaginationFailBeforeDatabaseAccess() {
        let missingGlobals = [
            "--library-db", "/definitely/missing/library.sqlite",
            "--annotations-db", "/definitely/missing/annotations.sqlite",
            "--json",
        ]

        let conflictingSelector = Capture()
        let selectorCode = CLIEntrypoint.run(
            arguments: ["books", "get", "12", "--pk", "12"] + missingGlobals,
            output: conflictingSelector.output
        )
        #expect(selectorCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(conflictingSelector.stderr.isEmpty)
        #expect(conflictingSelector.stdout.contains("usage_invalid"))
        #expect(conflictingSelector.stdout.contains("Database override") == false)

        let conflictingPage = Capture()
        let pageCode = CLIEntrypoint.run(
            arguments: ["books", "list", "--all", "--limit", "1"] + missingGlobals,
            output: conflictingPage.output
        )
        #expect(pageCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(conflictingPage.stderr.isEmpty)
        #expect(conflictingPage.stdout.contains("usage_invalid"))
        #expect(conflictingPage.stdout.contains("Database override") == false)
    }

    @Test
    func humanListUsesStdoutOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["books", "list"] + fixture.globalArguments,
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("total: 3"))
        #expect(capture.stdout.contains("Alpha"))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }

    private enum FixtureError: Error {
        case sqliteOpen(Int32)
        case sqliteExec(Int32)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL

        var globalArguments: [String] {
            [
                "--library-db", library.path,
                "--annotations-db", annotations.path,
                "--config", config.path,
            ]
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(library, sql: Self.librarySQL)
            try Self.createDatabase(annotations, sql: Self.annotationSQL)
            try Data("{}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw FixtureError.sqliteOpen(open)
            }
            defer { sqlite3_close_v2(handle) }
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw FixtureError.sqliteExec(result)
            }
        }

        private static let librarySQL = """
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
          (Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZBOOKDESCRIPTION,ZEPUBID,ZGENRE,ZGENRES,ZCOMMENTS,ZLANGUAGE,ZYEAR,ZCONTENTTYPE,ZPAGECOUNT,ZPATH,ZFILESIZE,ZCOVERURL,ZISFINISHED,ZREADINGPROGRESS,ZDURATION,ZCREATIONDATE,ZMODIFICATIONDATE,ZLASTOPENDATE,ZPURCHASEDATE,ZRELEASEDATE,ZISEXPLICIT,ZISLOCKED,ZISEPHEMERAL,ZISHIDDEN,ZISSAMPLE,ZISSTOREAUDIOBOOK,ZRATING)
        VALUES
          (1,'12','Alpha','Ada\u{E000} Author','Alpha description','epub-alpha','Fiction',X'0102','alpha comments','en',2024,1,100,'/tmp/alpha.epub',123,'cover-alpha',0,0.5,2000,10,20,30,40,50,0,0,0,0,0,0,4.5);
        INSERT INTO ZBKLIBRARYASSET (Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZGENRE,ZCONTENTTYPE) VALUES
          (12,'asset-pk-12','Numeric','Nora','Reference',1),
          (3,'history-id','Beta','Bob','History',1),
          (4,'null-content','Gamma','Cara','Fiction',NULL);
        """

        private static let annotationSQL = """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'12',0,1),
          (2,'12',0,3),
          (3,'history-id',0,1),
          (4,'history-id',1,1);
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
}

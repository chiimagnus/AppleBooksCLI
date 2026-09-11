import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("BooksCommandTests")
struct BooksCommandTests {
    @Test
    func listUsesWholeLibraryUniverseAndOpaqueCursorWithoutRawBookFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstCapture = Capture()
        let firstCode = CLIEntrypoint.run(
            arguments: ["books", "list", "--limit", "2"] + fixture.globalArguments,
            output: firstCapture.output
        )
        #expect(firstCode == CLIProcessExit.success.rawValue)
        #expect(firstCapture.stderr.isEmpty)
        let first = try decode(BookSummaryPageResult.self, firstCapture.stdout)
        #expect(first.total == 9)
        #expect(first.items.count == 2)
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let secondCapture = Capture()
        let secondCode = CLIEntrypoint.run(
            arguments: ["books", "list", "--limit", "100", "--cursor", cursor] + fixture.globalArguments,
            output: secondCapture.output
        )
        #expect(secondCode == CLIProcessExit.success.rawValue)
        let second = try decode(BookSummaryPageResult.self, secondCapture.stdout)
        #expect(second.hasMore == false)
        #expect(second.nextCursor == nil)
        #expect(first.items.count + second.items.count == 9)
        #expect((first.items + second.items).contains { $0.assetID == "null-content" })

        let raw = try jsonObject(firstCapture.stdout)
        let items = try #require(raw["items"] as? [[String: Any]])
        for item in items {
            #expect(item["path"] == nil)
            #expect(item["contentType"] == nil)
            #expect(item["comments"] == nil)
            #expect(item["genresRaw"] == nil)
        }
    }

    @Test
    func getReturnsSemanticDetailAndStableIdentityFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let assetCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", "12"] + fixture.globalArguments,
            output: assetCapture.output
        ) == CLIProcessExit.success.rawValue)
        let asset = try decode(BookDetailResult.self, assetCapture.stdout)
        #expect(asset.assetID == "12")
        #expect(asset.localPK == nil)
        #expect(asset.author == "Ada Author")
        #expect(asset.description == "Alpha description")
        #expect(asset.readingProgressPercent == 50)
        #expect(asset.isPDF == false)

        let pdfCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", "--pk", "12"] + fixture.globalArguments,
            output: pdfCapture.output
        ) == CLIProcessExit.success.rawValue)
        let pdf = try decode(BookDetailResult.self, pdfCapture.stdout)
        #expect(pdf.assetID == "asset-pk-12")
        #expect(pdf.localPK == nil)
        #expect(pdf.author == nil)
        #expect(pdf.readingProgressPercent == 100)
        #expect(pdf.isPDF == true)

        let negativeCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", "history-id"] + fixture.globalArguments,
            output: negativeCapture.output
        ) == CLIProcessExit.success.rawValue)
        #expect(try decode(BookDetailResult.self, negativeCapture.stdout).readingProgressPercent == 0)

        let raw = try jsonObject(assetCapture.stdout)
        for removed in [
            "epubID", "path", "contentType", "genresRaw", "comments", "coverURL",
            "readingProgressRaw", "durationRawMilliseconds", "normalizedAuthor",
        ] {
            #expect(raw[removed] == nil)
        }
    }

    @Test
    func getSanitizesNonFiniteSemanticRealWhileCoreKeepsRawFidelity() throws {
        let fixture = try Fixture(librarySQL: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZREADINGPROGRESS REAL,
              ZDURATION REAL,
              ZRATING REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES(1, 'non-finite', 9e999, 9e999, 9e999);
            """)
        defer { fixture.remove() }

        let connection = try SQLiteConnection.readOnly(path: fixture.library.path)
        let raw = try #require(BookQueries(connection: connection).getByAssetID("non-finite").first)
        #expect(raw.readingProgressRaw?.isInfinite == true)
        #expect(raw.durationRawMilliseconds?.isInfinite == true)
        #expect(raw.rating?.isInfinite == true)

        let capture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", "non-finite"] + fixture.globalArguments,
            output: capture.output
        ) == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(try decode(BookDetailResult.self, capture.stdout).readingProgressPercent == nil)
        let object = try jsonObject(capture.stdout)
        #expect(object["readingProgressPercent"] == nil)
    }

    @Test
    func searchUsesFieldAndCursorAndGenreRouteIsGone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "search", "Fiction", "--field", "genre", "--limit", "1"] + fixture.globalArguments,
            output: firstCapture.output
        ) == CLIProcessExit.success.rawValue)
        let first = try decode(BookSummaryPageResult.self, firstCapture.stdout)
        #expect(first.total == 2)
        #expect(first.items.count == 1)
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let secondCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "search", "Fiction", "--field", "genre", "--limit", "100", "--cursor", cursor] + fixture.globalArguments,
            output: secondCapture.output
        ) == CLIProcessExit.success.rawValue)
        let second = try decode(BookSummaryPageResult.self, secondCapture.stdout)
        #expect(second.items.count == 1)
        #expect(second.hasMore == false)
        #expect(Set((first.items + second.items).compactMap(\.assetID)) == ["12", "null-content"])

        let mismatch = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "search", "Fiction", "--field", "title", "--cursor", cursor] + fixture.globalArguments,
            output: mismatch.output
        ) == CLIProcessExit.usageInvalid.rawValue)
        #expect(mismatch.stdout.isEmpty)

        let removed = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "genre", "Fiction"] + fixture.globalArguments,
            output: removed.output
        ) == CLIProcessExit.usageInvalid.rawValue)
    }

    @Test
    func annotatedListUsesTwoStoreCursorAndCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "list", "--annotated", "--limit", "1"] + fixture.globalArguments,
            output: firstCapture.output
        ) == CLIProcessExit.success.rawValue)
        let first = try decode(BookSummaryPageResult.self, firstCapture.stdout)
        #expect(first.total == nil)
        #expect(first.items.count == 1)
        #expect(first.items[0].userAnnotationCount == 1)
        let cursor = try #require(first.nextCursor)

        let secondCapture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "list", "--annotated", "--cursor", cursor] + fixture.globalArguments,
            output: secondCapture.output
        ) == CLIProcessExit.success.rawValue)
        let second = try decode(BookSummaryPageResult.self, secondCapture.stdout)
        #expect(second.items.count == 1)
        #expect(second.items[0].userAnnotationCount == 1)
        #expect(second.hasMore == false)
        #expect(Set((first.items + second.items).compactMap(\.assetID)) == ["12", "history-id"])
    }

    @Test
    func invalidInputsAndRemovedPaginationFailBeforeDatabaseAccess() {
        let missingGlobals = [
            "--library-db", "/definitely/missing/library.sqlite",
            "--annotations-db", "/definitely/missing/annotations.sqlite",
        ]
        let cases = [
            ["books", "list", "--all"],
            ["books", "list", "--offset", "1"],
            ["books", "list", "--limit", "101"],
            ["books", "list", "--cursor", "é"],
            ["books", "get", String(repeating: "x", count: 2_049)],
            ["books", "get", " leading"],
            ["books", "get", "trailing "],
            ["books", "get", "abc\0def"],
            ["books", "search", String(repeating: "q", count: 513)],
        ]
        for arguments in cases {
            let capture = Capture()
            #expect(CLIEntrypoint.run(arguments: arguments + missingGlobals, output: capture.output) == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }
    }

    @Test
    func summaryUsesFallbackPKForIneligibleIdentityAndBoundsTextAtCharacterBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "list", "--limit", "100"] + fixture.globalArguments,
            output: capture.output
        ) == CLIProcessExit.success.rawValue)
        let page = try decode(BookSummaryPageResult.self, capture.stdout)

        let missingIdentity = try #require(page.items.first { $0.title == "No Identity" })
        #expect(missingIdentity.assetID == nil)
        #expect(missingIdentity.localPK == 5)

        let oversizedIdentity = try #require(page.items.first { $0.title == "Oversize Identity" })
        #expect(oversizedIdentity.assetID == nil)
        #expect(oversizedIdentity.localPK == 6)

        let edgeWhitespace = try #require(page.items.first { $0.title == "Whitespace Identity" })
        #expect(edgeWhitespace.assetID == nil)
        #expect(edgeWhitespace.localPK == 8)

        let exactLimitIdentity = try #require(page.items.first { $0.title == "Exact Identity Limit" })
        #expect(exactLimitIdentity.assetID?.utf8.count == 2_048)
        #expect(exactLimitIdentity.localPK == nil)

        let exactGet = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", String(repeating: "x", count: 2_048)] + fixture.globalArguments,
            output: exactGet.output
        ) == CLIProcessExit.success.rawValue)
        #expect(try decode(BookDetailResult.self, exactGet.stdout).assetID?.utf8.count == 2_048)

        let longTitle = try #require(page.items.first { $0.assetID == "long-title" })
        #expect(longTitle.title?.count == 512)
        #expect(longTitle.truncatedFields == ["title"])

        #expect(PublicStableTokenPolicy.isEligible("abc\0def") == false)
        let nulIdentityResult = BookSummaryResult(summary: BookSummary(
            localPK: 77,
            assetID: "abc\0def",
            title: "NUL Identity",
            author: nil,
            contentType: nil
        ))
        #expect(nulIdentityResult.assetID == nil)
        #expect(nulIdentityResult.localPK == 77)
        #expect(PublicStableTokenPolicy.isEligible(" leading") == false)
        #expect(PublicStableTokenPolicy.isEligible("trailing ") == false)
        #expect(PublicStableTokenPolicy.isEligible(String(repeating: "x", count: 2_048)))
        #expect(PublicStableTokenPolicy.isEligible(String(repeating: "x", count: 2_049)) == false)

        let hugeGrapheme = "e" + String(repeating: "\u{301}", count: 5_000)
        let bounded = BoundedTextPolicy.truncate(hugeGrapheme, profile: .metadata)
        #expect(bounded.truncated)
        #expect(bounded.value == "")
    }

    @Test
    func invalidUTF8DatabaseTextFailsWithSanitizedUnavailableError() throws {
        let fixture = try Fixture(librarySQL: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES(1, 'asset-safe', CAST(X'736563726574FF' AS TEXT));
            """)
        defer { fixture.remove() }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["books", "list"] + fixture.globalArguments,
            output: capture.output
        )

        #expect(code == CLIProcessExit.unavailable.rawValue)
        #expect(capture.stdout.isEmpty)
        let error = try jsonObject(capture.stderr)
        let payload = try #require(error["error"] as? [String: Any])
        #expect(payload["code"] as? String == "unavailable")
        #expect(payload["message"] as? String == "Apple Books data is unavailable.")
        #expect(capture.stderr.contains("secret") == false)
    }

    @Test
    func nonPositiveDatabasePKIsNeverPublishedAsFallbackIdentity() throws {
        let fixture = try Fixture(librarySQL: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES(0, NULL, 'Invalid Local Identity');
            """)
        defer { fixture.remove() }

        let capture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "list"] + fixture.globalArguments,
            output: capture.output
        ) == CLIProcessExit.success.rawValue)
        let page = try decode(BookSummaryPageResult.self, capture.stdout)
        let item = try #require(page.items.first)
        #expect(item.assetID == nil)
        #expect(item.localPK == nil)
    }

    @Test
    func missingGetUsesStableNotFoundErrorEnvelope() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()
        #expect(CLIEntrypoint.run(
            arguments: ["books", "get", "missing"] + fixture.globalArguments,
            output: capture.output
        ) == CLIProcessExit.notFound.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(try decode(CLIErrorEnvelope.self, capture.stderr).error.code == .notFound)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(text.utf8))
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
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

        init(librarySQL: String = Fixture.librarySQL) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(library, sql: librarySQL)
            try Self.createDatabase(annotations, sql: Self.annotationSQL)
            try Data("{}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqliteOpen(open) }
            defer { sqlite3_close_v2(handle) }
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else { throw FixtureError.sqliteExec(result) }
        }

        private static let librarySQL: String = {
            let exactIdentity = String(repeating: "x", count: 2_048)
            let oversizedIdentity = String(repeating: "y", count: 2_049)
            let longTitle = String(repeating: "界", count: 513)
            return """
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
            INSERT INTO ZBKLIBRARYASSET (Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZGENRE,ZCONTENTTYPE,ZREADINGPROGRESS) VALUES
              (12,'asset-pk-12','Numeric','UnknownAuthor','Reference',3,1.25),
              (3,'history-id','Beta','Bob','History',1,-0.2),
              (4,'null-content','Gamma','Cara','Fiction',NULL,NULL),
              (5,NULL,'No Identity','Nia','Other',1,NULL),
              (6,'\(oversizedIdentity)','Oversize Identity','Omar','Other',1,NULL),
              (7,'\(exactIdentity)','Exact Identity Limit','Eve','Other',1,NULL),
              (8,' leading-id','Whitespace Identity','Wes','Other',1,NULL),
              (9,'long-title','\(longTitle)','Lina','Other',1,NULL);
            """
        }()

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

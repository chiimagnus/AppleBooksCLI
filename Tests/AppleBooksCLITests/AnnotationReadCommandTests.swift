import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("AnnotationReadCommandTests")
struct AnnotationReadCommandTests {
    @Test
    func rootRegistersAnnotationReadSurface() {
        let capture = Capture()
        let code = CLIEntrypoint.run(arguments: ["annotations", "--help"], output: capture.output)

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("list"))
        #expect(capture.stdout.contains("get"))
        #expect(capture.stdout.contains("search"))
        #expect(capture.stdout.contains("recent"))
        #expect(capture.stdout.contains("range"))
    }

    @Test
    func listUsesExactBookSelectorsScopesAndCreationOrderedGrouping() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byAsset = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--book", "123"]
        )
        #expect(byAsset.items.map(\.localPK) == [2, 1])

        let byPK = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--book-pk", "123"]
        )
        #expect(byPK.items.map(\.localPK) == [123])

        let user = try fixture.runJSON(AnnotationCollectionResult.self, ["annotations", "list"])
        #expect(user.items.contains(where: { $0.localPK == 3 }) == false)
        #expect(user.items.contains(where: { $0.localPK == 4 }) == false)

        let raw = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--scope", "active-raw"]
        )
        #expect(raw.items.contains(where: { $0.localPK == 3 }))
        #expect(raw.items.contains(where: { $0.localPK == 4 }) == false)

        let grouped = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--group-by", "book"]
        )
        #expect(grouped.items.map(\.localPK) == [123, 7, 5, 6, 1, 2])
        let groups = try #require(grouped.groups)
        #expect(groups.flatMap(\.annotationLocalPKs).sorted() == grouped.items.map(\.localPK).sorted())
        #expect(groups.contains(where: { $0.source.kind == "historicalInferred" && $0.rawAssetID == "history-id" }))
        #expect(groups.contains(where: { $0.source.kind == "unmapped" && $0.rawAssetID == "orphan-id" }))
    }

    @Test
    func readingOrderRequiresUserBookContextAndCrossBookGroupingKeepsEveryRowOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let grouped = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--group-by", "book", "--order", "reading"]
        )
        #expect(grouped.items.map(\.localPK) == [2, 1, 5, 123, 6, 7])
        #expect(Set(grouped.items.map(\.localPK)).count == grouped.items.count)
        let groups = try #require(grouped.groups)
        #expect(groups.map(\.annotationLocalPKs) == [[2, 1], [5], [123], [6], [7]])
        #expect(groups.map(\.source.kind) == [
            "currentLibrary",
            "currentLibrary",
            "currentLibrary",
            "historicalInferred",
            "unmapped",
        ])

        let page = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "list", "--group-by", "book", "--order", "reading", "--limit", "3", "--offset", "1"]
        )
        #expect(page.items.map(\.localPK) == [1, 5, 123])
        #expect(page.groups?.map(\.annotationLocalPKs) == [[1], [5], [123]])

        let missingGlobals = Fixture.missingGlobalArguments
        for arguments in [
            ["annotations", "list", "--order", "reading"],
            ["annotations", "list", "--group-by", "book", "--order", "reading", "--scope", "active-raw"],
            ["annotations", "list", "--limit", "-1"],
            ["annotations", "list", "--offset", "-1"],
            ["annotations", "list", "--book", "123", "--book-pk", "123"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect(capture.stdout.contains("Database override") == false)
        }
    }

    @Test
    func getKeepsNumericUUIDSeparateFromExplicitPKAndScopeIsExplicit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byUUID = try fixture.runJSON(AnnotationResult.self, ["annotations", "get", "123"])
        #expect(byUUID.localPK == 1)
        #expect(byUUID.uuid == "123")
        #expect(byUUID.rawAssetID == "123")
        #expect(byUUID.type == 1)
        #expect(byUUID.style == 3)
        #expect(byUUID.isUnderline == true)
        #expect(byUUID.physicalLocation == 10)
        #expect(byUUID.rangeStart == 11)
        #expect(byUUID.rangeEnd == 12)
        #expect(byUUID.rawCFI == "epubcfi(/6/2[ch-one]!/4/2,:0,:0)")
        #expect(byUUID.source.kind == "currentLibrary")
        #expect(byUUID.source.bookLocalPK == 1)

        let byPK = try fixture.runJSON(AnnotationResult.self, ["annotations", "get", "--pk", "123"])
        #expect(byPK.localPK == 123)
        #expect(byPK.uuid == "other")
        #expect(byPK.rawAssetID == "asset-pk-123")

        let hidden = Capture()
        let hiddenCode = CLIEntrypoint.run(
            arguments: ["annotations", "get", "type3-private"] + fixture.globalArguments + ["--json"],
            output: hidden.output
        )
        #expect(hiddenCode == CLIProcessExit.notFound.rawValue)
        #expect(hidden.stdout.contains("type3-private") == false)

        let raw = try fixture.runJSON(
            AnnotationResult.self,
            ["annotations", "get", "type3-private", "--scope", "active-raw"]
        )
        #expect(raw.localPK == 3)
        #expect(raw.type == 3)

        let deleted = Capture()
        let deletedCode = CLIEntrypoint.run(
            arguments: ["annotations", "get", "deleted-private", "--scope", "active-raw"] + fixture.globalArguments + ["--json"],
            output: deleted.output
        )
        #expect(deletedCode == CLIProcessExit.notFound.rawValue)
        #expect(deleted.stdout.contains("deleted-private") == false)
    }

    @Test
    func searchDelegatesLiteralFieldAndColorFilteringBeforePagination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let literal = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "search", "%_\\", "--field", "highlight"]
        )
        #expect(literal.items.map(\.localPK) == [1])

        let greenPage = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "search", "needle", "--color", "green", "--limit", "1", "--offset", "1"]
        )
        #expect(greenPage.items.map(\.localPK) == [5])

        let note = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "search", "historical", "--field", "note", "--color", "purple"]
        )
        #expect(note.items.map(\.localPK) == [6])

        let missing = Fixture.missingGlobalArguments
        for arguments in [
            ["annotations", "search", "", "--field", "all"],
            ["annotations", "search", "needle", "--limit", "0"],
            ["annotations", "search", "needle", "--offset", "-1"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + missing, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect(capture.stdout.contains("Database override") == false)
        }
    }

    @Test
    func recentUsesDistinctCreatedUserAndModifiedActiveRawOwners() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let created = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "recent", "--time-field", "created"]
        )
        #expect(created.items.map(\.localPK) == [123, 7, 5, 6, 1, 2])
        #expect(created.items.contains(where: { $0.localPK == 3 }) == false)

        let modified = try fixture.runJSON(
            AnnotationCollectionResult.self,
            ["annotations", "recent", "--time-field", "modified"]
        )
        #expect(modified.items.map(\.localPK) == [3, 2, 1, 5, 6, 7, 123])
        #expect(modified.items.first?.type == 3)
    }

    @Test
    func rangeMapsRFC3339ToCoreHalfOpenCreationBounds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try fixture.runJSON(
            AnnotationCollectionResult.self,
            [
                "annotations", "range",
                "--after", "2001-01-01T00:01:40Z",
                "--before", "2001-01-01T00:02:10Z",
            ]
        )
        #expect(Set(result.items.map(\.localPK)) == [1, 5, 6])
        #expect(result.items.contains(where: { $0.localPK == 7 }) == false)
        #expect(result.items.contains(where: { $0.localPK == 3 }) == false)
    }

    @Test
    func dateOnlyBoundsUseCalendarDaysAcrossDSTInsteadOfFixedSeconds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let parser = AnnotationDateRangeParser(calendar: calendar)

        let spring = try parser.parse(after: "2026-03-08", before: "2026-03-08")
        let springLower = try #require(spring.lowerInclusive)
        let springUpper = try #require(spring.upperExclusive)
        #expect(springUpper.timeIntervalSince(springLower) == 23 * 60 * 60)

        let fall = try parser.parse(after: "2026-11-01", before: "2026-11-01")
        let fallLower = try #require(fall.lowerInclusive)
        let fallUpper = try #require(fall.upperExclusive)
        #expect(fallUpper.timeIntervalSince(fallLower) == 25 * 60 * 60)

        #expect(throws: ValidationError.self) {
            _ = try parser.parse(after: "2026-02-30", before: nil)
        }
    }

    @Test
    func invalidRangeIsRejectedBeforeDatabaseDiscovery() {
        for arguments in [
            ["annotations", "range"],
            ["annotations", "range", "--after", "2026-01-02", "--before", "2026-01-01"],
            ["annotations", "range", "--after", "not-a-date"],
            ["annotations", "range", "--after", "2026-01-01", "--limit", "-1"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + Fixture.missingGlobalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect(capture.stdout.contains("Database override") == false)
        }
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL

        static let missingGlobalArguments = [
            "--library-db", "/definitely/missing/applebookscli-t10-library.sqlite",
            "--annotations-db", "/definitely/missing/applebookscli-t10-annotations.sqlite",
            "--json",
        ]

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
            try Data(#"{"historical_assets":{"history-id":{"title":"History Book","author":"Hana"}}}"#.utf8)
                .write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + globalArguments + ["--json"],
                output: capture.output
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            return try decode(type, capture.stdout)
        }

        private func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(text.utf8))
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static let librarySQL = """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT,
          ZPATH TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'123','Book One','Ada',NULL),
          (2,'asset-two','Book Two','Bob',NULL),
          (123,'asset-pk-123','Numeric Book','Nora',NULL);
        """

        private static let annotationSQL = """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
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
          ZFUTUREPROOFING5 TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'123','123',0,1,3,1,100,200,'literal %_\\ needle','representative one','note alpha','epubcfi(/6/2[ch-one]!/4/2,:0,:0)',10,11,12,'chapter one'),
          (2,'uuid-two-old','123',0,0,1,1,50,300,'green needle','representative two','note beta','epubcfi(/6/2[ch-one]!/4/2,:0,:0)',20,21,22,'chapter one'),
          (3,'type3-private','123',0,0,1,3,150,500,'green needle type3',NULL,NULL,NULL,NULL,NULL,NULL,NULL),
          (4,'deleted-private','123',1,0,1,1,250,600,'deleted needle',NULL,NULL,NULL,NULL,NULL,NULL,NULL),
          (5,'book-two','asset-two',0,0,1,1,120,100,'green needle book two',NULL,'note book two',NULL,30,31,32,NULL),
          (6,'history','history-id',0,0,5,1,110,90,NULL,'history representative','historical needle',NULL,40,41,42,NULL),
          (7,'orphan','orphan-id',0,0,2,1,130,80,NULL,'orphan needle',NULL,NULL,50,51,52,NULL),
          (123,'other','asset-pk-123',0,0,4,1,140,70,'numeric pk',NULL,NULL,NULL,60,61,62,NULL);
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

    private enum FixtureError: Error {
        case sqlite
    }
}

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
        #expect(capture.stdout.contains("update-note"))
        #expect(capture.stdout.contains("delete"))
        #expect(capture.stdout.contains("search") == false)
        #expect(capture.stdout.contains("recent") == false)
        #expect(capture.stdout.contains("range") == false)
    }

    @Test
    func listUsesCanonicalQueryEnvelopeStableSelectorsAndCursor() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byAsset = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book", "123"]
        )
        #expect(byAsset.items.map(\.uuid) == ["uuid-two-old", "123"])
        #expect(byAsset.items.allSatisfy { $0.localPK == nil })
        #expect(byAsset.hasMore == false)
        #expect(byAsset.nextCursor == nil)
        #expect(byAsset.items[0].quotePreview == "green needle")
        #expect(byAsset.items[0].notePreview == "note beta")
        #expect(byAsset.items[0].color == "green")
        #expect(byAsset.items[0].underline == false)
        #expect(byAsset.items[0].hasHighlight)
        #expect(byAsset.items[0].hasNote)

        let first = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book", "123", "--limit", "1"]
        )
        let cursor = try #require(first.nextCursor)
        #expect(first.items.map(\.uuid) == ["uuid-two-old"])
        #expect(first.hasMore)
        let second = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book", "123", "--limit", "1", "--cursor", cursor]
        )
        #expect(second.items.map(\.uuid) == ["123"])
        #expect(second.hasMore == false)
        #expect(second.nextCursor == nil)

        let byPK = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book-pk", "123"]
        )
        #expect(byPK.items.map(\.uuid) == ["other"])

        let user = try fixture.runJSON(AnnotationListResult.self, ["annotations", "list"])
        #expect(user.items.map(\.uuid) == ["uuid-two-old", "123", "book-two", "history", "orphan", "other"])
        #expect(user.items.first(where: { $0.uuid == "123" })?.source.bookAssetID == "123")
        #expect(user.items.first(where: { $0.uuid == "history" })?.source.bookAssetID == "history-id")
        #expect(user.items.first(where: { $0.uuid == "orphan" })?.source.bookAssetID == "orphan-id")
    }

    @Test
    func readingOrderRequiresExactBookAndRemovedLegacyListOptionsFailBeforeIO() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let reading = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book", "123", "--order", "reading"]
        )
        #expect(reading.items.map(\.uuid) == ["123", "uuid-two-old"])

        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["annotations", "list", "--help"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stdout.contains("--group-by") == false)
        #expect(help.stdout.contains("--scope") == false)
        #expect(help.stdout.contains("--offset") == false)
        #expect(help.stdout.contains("--cursor"))
        #expect(help.stdout.contains("--created-after"))
        #expect(help.stdout.contains("--has-note"))
        #expect(help.stderr.isEmpty)

        let missingGlobals = Fixture.missingGlobalArguments
        for arguments in [
            ["annotations", "list", "--order", "reading"],
            ["annotations", "list", "--scope", "active-raw"],
            ["annotations", "list", "--group-by", "book"],
            ["annotations", "list", "--limit", "-1"],
            ["annotations", "list", "--offset", "1"],
            ["annotations", "list", "--book", "123", "--book-pk", "123"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }
    }

    @Test
    func canonicalListInputsFailBeforeDatabaseDiscoveryAndCombinedFiltersMapToCore() throws {
        let missingGlobals = Fixture.missingGlobalArguments
        let tooLongTimestamp = "2001-01-01T00:00:00Z" + String(repeating: "0", count: 45)
        for arguments in [
            ["annotations", "list", "--created-after", "2001-01-01"],
            ["annotations", "list", "--created-after", "2001-01-01T00:00:00"],
            ["annotations", "list", "--created-after", tooLongTimestamp],
            ["annotations", "list", "--created-after", "2001-01-01T00:00:00Zé"],
            ["annotations", "list", "--text-field", "note"],
            ["annotations", "list", "--text", " \t\r\n"],
            ["annotations", "list", "--has-note", "maybe"],
            ["annotations", "list", "--underline", "1"],
            ["annotations", "list", "--cursor", "!"],
            ["annotations", "list", "--limit", "101"],
            ["annotations", "list", "--book", " bad "],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        let combined = try fixture.runJSON(
            AnnotationListResult.self,
            [
                "annotations", "list",
                "--book", "123",
                "--text", "note alpha",
                "--text-field", "note",
                "--created-after", "2001-01-01T01:01:40+01:00",
                "--created-before", "2001-01-01T00:01:41Z",
                "--modified-after", "2001-01-01T00:03:20Z",
                "--modified-before", "2001-01-01T00:03:21Z",
                "--color", "yellow",
                "--underline", "true",
                "--has-highlight", "true",
                "--has-note", "true",
                "--order", "created",
            ]
        )
        #expect(combined.items.map(\.uuid) == ["123"])
    }

    @Test
    func getUsesSafeDetailDTOAndKeepsNumericUUIDSeparateFromExplicitPK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byUUID = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "123"])
        #expect(byUUID.uuid == "123")
        #expect(byUUID.localPK == nil)
        #expect(byUUID.selectedText == "literal %_\\ needle")
        #expect(byUUID.note == "note alpha")
        #expect(byUUID.color == "yellow")
        #expect(byUUID.underline)
        #expect(byUUID.hasHighlight)
        #expect(byUUID.hasNote)
        #expect(byUUID.chapterID == "ch-one")
        #expect(byUUID.bookURL == "ibooks://assetid/123")
        #expect(byUUID.source.kind == "currentLibrary")
        #expect(byUUID.source.bookAssetID == "123")
        #expect(byUUID.source.bookLocalPK == nil)

        let byPK = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "--pk", "123"])
        #expect(byPK.uuid == "other")
        #expect(byPK.localPK == nil)
        #expect(byPK.source.bookAssetID == "asset-pk-123")
        #expect(byPK.bookURL == "ibooks://assetid/asset-pk-123")

        let hidden = Capture()
        let hiddenCode = CLIEntrypoint.run(
            arguments: ["annotations", "get", "type3-private"] + fixture.globalArguments,
            output: hidden.output
        )
        #expect(hiddenCode == CLIProcessExit.notFound.rawValue)
        #expect(hidden.stdout.isEmpty)
        #expect(hidden.stderr.contains("type3-private") == false)

        let deleted = Capture()
        let deletedCode = CLIEntrypoint.run(
            arguments: ["annotations", "get", "deleted-private"] + fixture.globalArguments,
            output: deleted.output
        )
        #expect(deletedCode == CLIProcessExit.notFound.rawValue)
        #expect(deleted.stdout.isEmpty)
        #expect(deleted.stderr.contains("deleted-private") == false)

        let defaultOutput = Capture()
        let defaultCode = CLIEntrypoint.run(
            arguments: ["annotations", "get", "123"] + fixture.globalArguments,
            output: defaultOutput.output
        )
        #expect(defaultCode == CLIProcessExit.success.rawValue)
        #expect(defaultOutput.stderr.isEmpty)
        #expect(defaultOutput.stdout.contains("rawCFI") == false)
        #expect(defaultOutput.stdout.contains("epubcfi") == false)
        #expect(defaultOutput.stdout.contains("rangeStart") == false)
        #expect(defaultOutput.stdout.contains("physicalLocation") == false)
        #expect(defaultOutput.stdout.contains("#") == false)
    }

    @Test
    func annotationAndSourceIdentitiesNeverTruncateAndFallbackSafely() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let uuid2048 = String(repeating: "u", count: 2_048)
        let uuid2049 = String(repeating: "v", count: 2_049)
        let asset2048 = String(repeating: "a", count: 2_048)
        let asset2049 = String(repeating: "b", count: 2_049)
        let oversizedAsset = String(repeating: "z", count: 70_000)
        try fixture.executeLibrary("""
        INSERT INTO ZBKLIBRARYASSET(Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZPATH) VALUES
          (1011,'\(asset2049)','Oversized Current','Olivia',NULL),
          (1013,'nul'||char(0)||'asset','NUL Current','Nora',NULL);
        """)
        try Data(#"{"historical_assets":{" bad ":{"title":"Boundary History","author":"Hana"}}}"#.utf8)
            .write(to: fixture.config)
        try fixture.executeAnnotations("""
        INSERT INTO ZAEANNOTATION(Z_PK,ZANNOTATIONUUID,ZANNOTATIONASSETID,ZANNOTATIONDELETED,ZANNOTATIONTYPE,ZANNOTATIONCREATIONDATE,ZANNOTATIONMODIFICATIONDATE) VALUES
          (1000,'\(uuid2048)','asset-boundary-a',0,1,1000,1000),
          (1001,'\(uuid2049)','asset-boundary-b',0,1,1001,1001),
          (1002,' bad ','asset-boundary-c',0,1,1002,1002),
          (1003,'nul'||char(0)||'uuid','asset-boundary-d',0,1,1003,1003),
          (1010,'source-2048','\(asset2048)',0,1,1010,1010),
          (1011,'source-2049','\(asset2049)',0,1,1011,1011),
          (1012,'source-space',' bad ',0,1,1012,1012),
          (1013,'source-nul','nul'||char(0)||'asset',0,1,1013,1013),
          (1014,'source-oversized','\(oversizedAsset)',0,1,1014,1014);
        """)

        let exactBoundary = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", uuid2048])
        #expect(exactBoundary.uuid == uuid2048)
        #expect(exactBoundary.localPK == nil)

        for localPK in [1001, 1002, 1003] {
            let fallback = try fixture.runJSON(
                AnnotationDetailResult.self,
                ["annotations", "get", "--pk", String(localPK)]
            )
            #expect(fallback.uuid == nil)
            #expect(fallback.localPK == Int64(localPK))
        }
        let listFallback = try fixture.runJSON(
            AnnotationListResult.self,
            [
                "annotations", "list",
                "--created-after", "2001-01-01T00:16:41Z",
                "--created-before", "2001-01-01T00:16:42Z",
            ]
        )
        #expect(listFallback.items.count == 1)
        #expect(listFallback.items[0].uuid == nil)
        #expect(listFallback.items[0].localPK == 1001)

        let sourceBoundary = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "source-2048"])
        #expect(sourceBoundary.source.kind == "unmapped")
        #expect(sourceBoundary.source.bookAssetID == asset2048)
        #expect(sourceBoundary.source.bookLocalPK == nil)

        let oversizedCurrent = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "source-2049"])
        #expect(oversizedCurrent.source.kind == "currentLibrary")
        #expect(oversizedCurrent.source.bookAssetID == nil)
        #expect(oversizedCurrent.source.bookLocalPK == 1011)
        #expect(oversizedCurrent.source.title == "Oversized Current")

        let whitespaceHistorical = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "source-space"])
        #expect(whitespaceHistorical.source.kind == "historicalInferred")
        #expect(whitespaceHistorical.source.bookAssetID == nil)
        #expect(whitespaceHistorical.source.bookLocalPK == nil)
        #expect(whitespaceHistorical.source.title == "Boundary History")

        let nulCurrent = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "source-nul"])
        #expect(nulCurrent.source.kind == "currentLibrary")
        #expect(nulCurrent.source.bookAssetID == nil)
        #expect(nulCurrent.source.bookLocalPK == 1013)
        #expect(nulCurrent.source.title == "NUL Current")

        let unavailable = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "source-oversized"])
        #expect(unavailable.source.kind == "identityUnavailable")
        #expect(unavailable.source.bookAssetID == nil)
        #expect(unavailable.source.bookLocalPK == nil)
    }

    @Test
    func storagePresenceDoesNotDependOnBoundedPreviewPrefix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let delayedHighlight = String(repeating: " ", count: 5_000) + "highlight"
        let delayedNote = String(repeating: "\t", count: 5_000) + "note"
        try fixture.executeAnnotations("""
        UPDATE ZAEANNOTATION
        SET ZANNOTATIONSELECTEDTEXT='\(delayedHighlight)',
            ZANNOTATIONNOTE='\(delayedNote)'
        WHERE Z_PK=1;
        """)

        let result = try fixture.runJSON(
            AnnotationListResult.self,
            ["annotations", "list", "--book", "123", "--order", "created"]
        )
        let item = try #require(result.items.first(where: { $0.uuid == "123" }))
        #expect(item.hasHighlight)
        #expect(item.hasNote)
        #expect(item.quotePreview == "representative one")
        #expect(item.notePreview == nil)
        #expect(item.truncatedFields.contains("quotePreview"))
        #expect(item.truncatedFields.contains("notePreview"))
    }

    @Test
    func detailBoundsBodiesHidesRawCFIAndReportsOversizedLocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = String(repeating: "s", count: 4_005)
        let note = String(repeating: "n", count: 4_005)
        let oversizedLocation = "epubcfi(/6/2[" + String(repeating: "x", count: 70_000) + "]!/4/2)"
        try fixture.executeAnnotations("""
        UPDATE ZAEANNOTATION
        SET ZANNOTATIONSELECTEDTEXT='\(selected)',
            ZANNOTATIONNOTE='\(note)',
            ZANNOTATIONLOCATION='\(oversizedLocation)'
        WHERE Z_PK=1;
        """)

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["annotations", "get", "123"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let detail = try fixture.decode(AnnotationDetailResult.self, capture.stdout)
        #expect(detail.selectedText?.count == 4_000)
        #expect(detail.note?.count == 4_000)
        #expect(detail.chapterID == nil)
        #expect(detail.truncatedFields.contains("selectedText"))
        #expect(detail.truncatedFields.contains("note"))
        #expect(detail.truncatedFields.contains("location"))
        #expect(capture.stdout.contains("epubcfi") == false)
        #expect(capture.stdout.contains(String(repeating: "x", count: 128)) == false)
    }

    @Test
    func bookLevelLinkUsesOnePercentEncodedSegmentAndRoundTripsIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let assetID = "asset/segment#query?percent%雪"
        try fixture.executeLibrary("""
        INSERT INTO ZBKLIBRARYASSET(Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZPATH)
        VALUES(200,'\(assetID)','Special','Author',NULL);
        """)
        try fixture.executeAnnotations("""
        INSERT INTO ZAEANNOTATION(Z_PK,ZANNOTATIONUUID,ZANNOTATIONASSETID,ZANNOTATIONDELETED,ZANNOTATIONTYPE,ZANNOTATIONCREATIONDATE,ZANNOTATIONMODIFICATIONDATE)
        VALUES(200,'special-url','\(assetID)',0,1,200,200);
        """)

        let detail = try fixture.runJSON(AnnotationDetailResult.self, ["annotations", "get", "special-url"])
        #expect(detail.source.bookAssetID == assetID)
        let url = try #require(detail.bookURL)
        let components = try #require(URLComponents(string: url))
        #expect(components.scheme == "ibooks")
        #expect(components.host == "assetid")
        #expect(components.fragment == nil)
        #expect(components.query == nil)
        let encodedSegment = String(components.percentEncodedPath.dropFirst())
        #expect(encodedSegment.contains("/") == false)
        #expect(encodedSegment.removingPercentEncoding == assetID)
        #expect(url.contains("%2F"))
        #expect(url.contains("%23"))
        #expect(url.contains("%3F"))
        #expect(url.contains("%25"))
    }

    @Test
    func removedQueryCommandsAndGetRawScopeFailBeforeDatabaseDiscovery() {
        for arguments in [
            ["annotations", "search", "needle"],
            ["annotations", "recent"],
            ["annotations", "range", "--after", "2001-01-01T00:00:00Z"],
            ["annotations", "get", "type3-private", "--scope", "active-raw"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + Fixture.missingGlobalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
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

        func executeLibrary(_ sql: String) throws {
            try Self.createDatabase(library, sql: sql)
        }

        func executeAnnotations(_ sql: String) throws {
            try Self.createDatabase(annotations, sql: sql)
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + globalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            return try decode(type, capture.stdout)
        }

        func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
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

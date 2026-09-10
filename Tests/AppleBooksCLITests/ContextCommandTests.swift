import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ContextCommandTests")
struct ContextCommandTests {
    @Test
    func annotationSurfaceUsesExactUUIDAndExplicitPKWithoutRichDTOs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byUUID = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "123", "--before", "20", "--after", "20"]
        )
        #expect(byUUID.uuid == "123")
        #expect(byUUID.localPK == nil)
        #expect(byUUID.matched == "quick\n\nbrown")
        #expect(byUUID.truncatedFields.isEmpty)

        let numericPK = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "--pk", "123", "--before", "20", "--after", "20"]
        )
        #expect(numericPK.uuid == "other")
        #expect(numericPK.localPK == nil)
        #expect(numericPK.matched == "brown fox")

        let fallbackPK = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "--pk", "7"]
        )
        #expect(fallbackPK.uuid == nil)
        #expect(fallbackPK.localPK == 7)
        #expect(fallbackPK.matched.contains("quick"))
    }

    @Test
    func asciiWhitespaceSelectedFallsBackToRepresentativeText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "whitespace-fallback", "--before", "20", "--after", "20"]
        )
        #expect(result.matched == "brown fox")
    }

    @Test
    func invalidWindowsMixedSelectorsAndRemovedContentRouteFailBeforeDatabaseAccess() throws {
        let missing = "/definitely/not-present/applebookscli-t11.sqlite"
        let globals = ["--library-db", missing, "--annotations-db", missing]
        let invalid: [[String]] = [
            ["annotations", "context", "123", "--before", "-1"],
            ["annotations", "context", "123", "--after", "2001"],
            ["annotations", "context", "123", "--pk", "1"],
            ["annotations", "context"],
            ["content", "context", "123"],
        ]
        for arguments in invalid {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }

        let annotationsHelp = Capture()
        #expect(CLIEntrypoint.run(arguments: ["annotations", "--help"], output: annotationsHelp.output) == 0)
        #expect(annotationsHelp.stdout.contains("context"))
        let contentHelp = Capture()
        #expect(CLIEntrypoint.run(arguments: ["content", "--help"], output: contentHelp.output) == 0)
        #expect(contentHelp.stdout.contains("context") == false)
    }

    @Test
    func anchorByteAndGraphemeBudgetsFailClosedWithoutReflectingText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let boundary = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "anchor-byte-boundary", "--before", "0", "--after", "0"]
        )
        #expect(boundary.matched.utf8.count == 32 * 1_024)
        #expect(boundary.matched.count <= 4_000)
        #expect(boundary.truncatedFields.isEmpty)

        for uuid in ["anchor-byte-overflow", "anchor-grapheme-overflow"] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["annotations", "context", uuid] + fixture.globalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(uuid) == false)
            #expect(capture.stderr.contains("aaaa") == false)
        }
    }

    @Test
    func oversizedLocationDuplicateBookAndUnsafePathsFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for uuid in [
            "location-overflow-private",
            "duplicate-book-private",
            "oversize-path-private",
            "huge-path-private",
            "missing-content-private",
            "drm-content-private",
            "missing-chapter-private",
            "anchor-miss-private",
            "duplicate-uuid",
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["annotations", "context", uuid] + fixture.globalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(uuid) == false)
            #expect(capture.stderr.contains("epubcfi") == false)
            #expect(capture.stderr.contains("quick brown") == false)
        }
    }

    @Test
    func defaultSideByteBudgetIsFourKiBAndAdjustedWindowUsesSixteenKiB() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let defaultWindow = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "byte-window"]
        )
        #expect(defaultWindow.before.utf8.count <= 4 * 1_024)
        #expect(defaultWindow.truncatedFields.contains("before"))
        #expect(defaultWindow.leadingTruncated)

        let adjusted = try fixture.runJSON(
            AnnotationContextResult.self,
            arguments: ["annotations", "context", "byte-window", "--before", "400"]
        )
        #expect(adjusted.before.utf8.count > 4 * 1_024)
        #expect(adjusted.before.utf8.count <= 16 * 1_024)
        #expect(adjusted.truncatedFields.contains("before") == false)
    }

    @Test
    func compactJSONDoesNotLeakRawCFIOrDuplicatePresentationFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["annotations", "context", "123", "--before", "20", "--after", "20"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let object = try #require(JSONSerialization.jsonObject(with: Data(capture.stdout.utf8)) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "uuid", "before", "matched", "after", "leadingTruncated", "trailingTruncated", "truncatedFields",
        ]))
        #expect(capture.stdout.contains("epubcfi") == false)
        #expect(capture.stdout.contains("canonicalText") == false)
        #expect(capture.stdout.contains("presentationText") == false)
        #expect(capture.stdout.contains("chapterID") == false)
        #expect(capture.stdout.contains("bookURL") == false)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL

        var globalArguments: [String] {
            ["--library-db", library.path, "--annotations-db", annotations.path, "--config", config.path]
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let readable = root.appendingPathComponent("readable.epub", isDirectory: true)
            let encrypted = root.appendingPathComponent("encrypted.epub", isDirectory: true)
            try Self.makeEPUB(at: readable, encrypted: false)
            try Self.makeEPUB(at: encrypted, encrypted: true)
            let missing = root.appendingPathComponent("missing.epub", isDirectory: true)

            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(
                library,
                sql: Self.librarySQL(readable: readable.path, missing: missing.path, encrypted: encrypted.path)
            )
            try Self.createDatabase(annotations, sql: Self.annotationSQL)
            try Data("{}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globalArguments, output: capture.output)
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            return try JSONDecoder().decode(type, from: Data(capture.stdout.utf8))
        }

        private static let anchorCluster = "e" + String(repeating: "\u{0301}", count: 4)
        private static let anchorByteBoundary = String(repeating: anchorCluster, count: 3_640) + "12345678"
        private static let anchorByteOverflow = String(repeating: anchorCluster, count: 3_640) + "123456789"
        private static let anchorGraphemeOverflow = String(repeating: "a", count: 4_001)
        private static let wideCluster = "e" + String(repeating: "\u{0301}", count: 8)
        private static let widePrefix = String(repeating: wideCluster, count: 400)

        private static func makeEPUB(at epub: URL, encrypted: Bool) throws {
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("""
            <package xmlns="http://www.idpf.org/2007/opf"><manifest>
              <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
              <item id="anchor" href="anchor.xhtml" media-type="application/xhtml+xml"/>
              <item id="wide" href="wide.xhtml" media-type="application/xhtml+xml"/>
            </manifest><spine><itemref idref="chapter"/><itemref idref="anchor"/><itemref idref="wide"/></spine></package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body><p>chapter opening that must not be returned zero prefix The quick</p><p>brown fox suffix end</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            try Data("<html><body><p>\(anchorByteBoundary)</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/anchor.xhtml"))
            try Data("<html><body><p>\(widePrefix)quick brown tail</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/wide.xhtml"))
            if encrypted {
                try Data("""
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
                  <enc:EncryptedData><enc:EncryptionMethod Algorithm="urn:synthetic:unsupported"/><enc:CipherData><enc:CipherReference URI="OPS/chapter.xhtml"/></enc:CipherData></enc:EncryptedData>
                </encryption>
                """.utf8).write(to: epub.appendingPathComponent("META-INF/encryption.xml"))
            }
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static func librarySQL(readable: String, missing: String, encrypted: String) -> String {
            let oversizePath = String(repeating: "p", count: 4_097)
            let hugePath = String(repeating: "h", count: 2 * 1_024 * 1_024)
            return """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZPATH TEXT,
              ZBOOKDESCRIPTION BLOB
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'asset-readable','\(sql(readable))',zeroblob(2097152)),
              (2,'asset-missing','\(sql(missing))',NULL),
              (3,'asset-encrypted','\(sql(encrypted))',NULL),
              (4,'asset-dup','\(sql(readable))',NULL),
              (5,'asset-dup','\(sql(readable))',NULL),
              (6,'asset-oversize-path','\(oversizePath)',NULL),
              (7,'asset-huge-path','\(hugePath)',NULL);
            """
        }

        private static var annotationSQL: String {
            let locationOverflow = String(repeating: "x", count: 64 * 1_024 + 1)
            return """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZANNOTATIONREPRESENTATIVETEXT TEXT,
              ZANNOTATIONLOCATION TEXT,
              ZANNOTATIONNOTE BLOB
            );
            INSERT INTO ZAEANNOTATION VALUES
              (1,'123','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',zeroblob(2097152)),
              (123,'other','asset-readable',0,1,'brown fox','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (2,'anchor-miss-private','asset-readable',0,1,'absent anchor that is private','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (3,'missing-chapter-private','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2!/4/2,:0,:0)',NULL),
              (4,'missing-content-private','asset-missing',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (5,'drm-content-private','asset-encrypted',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (6,'whitespace-fallback','asset-readable',0,1,' \t\r\n','brown fox','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (7,NULL,'asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (8,'anchor-byte-boundary','asset-readable',0,1,'\(sql(anchorByteBoundary))','wrong','epubcfi(/6/2[anchor]!/4/2,:0,:0)',NULL),
              (9,'anchor-byte-overflow','asset-readable',0,1,'\(sql(anchorByteOverflow))','wrong','epubcfi(/6/2[anchor]!/4/2,:0,:0)',NULL),
              (10,'anchor-grapheme-overflow','asset-readable',0,1,'\(anchorGraphemeOverflow)','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (11,'location-overflow-private','asset-readable',0,1,'quick brown','wrong','\(locationOverflow)',NULL),
              (12,'duplicate-book-private','asset-dup',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (13,'oversize-path-private','asset-oversize-path',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (14,'huge-path-private','asset-huge-path',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (15,'byte-window','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[wide]!/4/2,:0,:0)',NULL),
              (16,'duplicate-uuid','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL),
              (17,'duplicate-uuid','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)',NULL);
            """
        }

        private static func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }
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

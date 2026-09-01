import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ContextCommandTests")
struct ContextCommandTests {
    @Test
    func exactUUIDAndExplicitPKUseOneSelectorGrammarAndCoreMarker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byUUID = try fixture.runJSON(
            ContentContextResult.self,
            arguments: ["content", "context", "123", "--before", "20", "--after", "20"]
        )
        #expect(byUUID.annotationLocalPK == 1)
        #expect(byUUID.annotationUUID == "123")
        #expect(byUUID.matched == "quick\n\nbrown")
        #expect(byUUID.canonicalText.contains("quick\n\nbrown"))
        #expect(byUUID.canonicalText.contains("«") == false)
        #expect(byUUID.matchFound)
        #expect(byUUID.presentationText.contains("«quick\n\nbrown»"))
        #expect(byUUID.presentationText.filter { $0 == "«" }.count == 1)

        let byPK = try fixture.runJSON(
            ContentContextResult.self,
            arguments: ["content", "context", "--pk", "123", "--before", "20", "--after", "20"]
        )
        #expect(byPK.annotationLocalPK == 123)
        #expect(byPK.annotationUUID == "other")
        #expect(byPK.matched == "brown fox")
        #expect(byPK.presentationText.contains("«brown fox»"))
    }

    @Test
    func negativeWindowsAndMixedSelectorsFailBeforeDatabaseAccess() throws {
        let missing = "/definitely/not-present/applebookscli-t9.sqlite"
        let globals = [
            "--library-db", missing,
            "--annotations-db", missing,
            "--json",
        ]

        for arguments in [
            ["content", "context", "123", "--before", "-1"],
            ["content", "context", "123", "--after", "-1"],
            ["content", "context", "123", "--pk", "1"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect(capture.stdout.contains("Database override") == false)
        }
    }

    @Test
    func anchorMissAndMissingChapterAreUnavailableWithoutLeakingPrivateInputs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for uuid in ["anchor-miss-private", "missing-chapter-private"] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["content", "context", uuid] + fixture.globalArguments + ["--json"],
                output: capture.output
            )
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stderr.isEmpty)
            let envelope = try fixture.decode(CLIErrorEnvelope.self, capture.stdout)
            #expect(envelope.error.code == .unavailable)
            #expect(envelope.error.message == "Annotation context is unavailable.")
            #expect(capture.stdout.contains(uuid) == false)
            #expect(capture.stdout.contains("chapter opening that must not be returned") == false)
            #expect(capture.stdout.contains("absent anchor that is private") == false)
        }
    }

    @Test
    func unavailableAndEncryptedContentStayStructuredWithoutContextFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for uuid in ["missing-content-private", "drm-content-private"] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["content", "context", uuid] + fixture.globalArguments + ["--json"],
                output: capture.output
            )
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stderr.isEmpty)
            let envelope = try fixture.decode(CLIErrorEnvelope.self, capture.stdout)
            #expect(envelope.error.code == .unavailable)
            #expect(capture.stdout.contains(uuid) == false)
            #expect(capture.stdout.contains("quick brown") == false)
        }
    }

    @Test
    func humanOutputUsesCoreMarkedPresentationOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "context", "123", "--before", "20", "--after", "20"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("«quick\n\nbrown»"))
        #expect(capture.stdout.filter { $0 == "«" }.count == 1)
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
            let code = CLIEntrypoint.run(
                arguments: arguments + globalArguments + ["--json"],
                output: capture.output
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            return try decode(type, capture.stdout)
        }

        func decode<Value: Decodable>(_ type: Value.Type, _ text: String) throws -> Value {
            try JSONDecoder().decode(type, from: Data(text.utf8))
        }

        private static func makeEPUB(at epub: URL, encrypted: Bool) throws {
            try FileManager.default.createDirectory(
                at: epub.appendingPathComponent("META-INF", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: epub.appendingPathComponent("OPS", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8)
                .write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body><p>chapter opening that must not be returned zero prefix The quick</p><p>brown fox suffix end</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            if encrypted {
                try Data("""
                <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
                  <enc:EncryptedData>
                    <enc:EncryptionMethod Algorithm="urn:synthetic:unsupported"/>
                    <enc:CipherData><enc:CipherReference URI="OPS/chapter.xhtml"/></enc:CipherData>
                  </enc:EncryptedData>
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
            """
            CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT);
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'asset-readable','\(sql(readable))'),
              (2,'asset-missing','\(sql(missing))'),
              (3,'asset-encrypted','\(sql(encrypted))');
            """
        }

        private static let annotationSQL = """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONUUID TEXT,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONREPRESENTATIVETEXT TEXT,
          ZANNOTATIONLOCATION TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'123','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (123,'other','asset-readable',0,1,'brown fox','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (2,'anchor-miss-private','asset-readable',0,1,'absent anchor that is private','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (3,'missing-chapter-private','asset-readable',0,1,'quick brown','wrong','epubcfi(/6/2!/4/2,:0,:0)'),
          (4,'missing-content-private','asset-missing',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (5,'drm-content-private','asset-encrypted',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)');
        """

        private static func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }
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

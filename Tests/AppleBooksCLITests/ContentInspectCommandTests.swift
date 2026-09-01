import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ContentInspectCommandTests")
struct ContentInspectCommandTests {
    @Test
    func statusUsesExactSelectorAndReportsMaterializationWithoutReadingChapterBody() throws {
        let fixture = try Fixture(contentAvailable: true, supplementalAvailable: true)
        defer { fixture.remove() }

        let byAsset = try fixture.runJSON(
            ContentStatusResult.self,
            arguments: ["content", "status", "12"]
        )
        #expect(byAsset.bookLocalPK == 1)
        #expect(byAsset.bookAssetID == "12")
        #expect(byAsset.currentAvailability == .available)
        #expect(byAsset.supplementalAvailability == .available)
        #expect(byAsset.selectedSource == .current)
        #expect(byAsset.materialization == .available)
        #expect(byAsset.encryption == EPUBEncryption.none)
        #expect(byAsset.unavailableReason == nil)
        #expect(byAsset.ready)

        let byPK = try fixture.runJSON(
            ContentStatusResult.self,
            arguments: ["content", "status", "--pk", "1"]
        )
        #expect(byPK.bookAssetID == "12")
    }

    @Test
    func unavailableStatusIsStructuredInsteadOfEmptySuccess() throws {
        let fixture = try Fixture(contentAvailable: false)
        defer { fixture.remove() }

        let status = try fixture.runJSON(
            ContentStatusResult.self,
            arguments: ["content", "status", "12"]
        )
        #expect(status.ready == false)
        #expect(status.currentAvailability == .missing)
        #expect(status.selectedSource == nil)
        #expect(status.materialization == .missing)
        #expect(status.unavailableReason == .missing)
    }

    @Test
    func statusClassifiesFontObfuscationAndUnsupportedDRMWithoutReadingChapterBody() throws {
        let font = try Fixture(contentAvailable: true, encryption: .fontObfuscation)
        defer { font.remove() }
        let fontStatus = try font.runJSON(
            ContentStatusResult.self,
            arguments: ["content", "status", "12"]
        )
        #expect(fontStatus.encryption == .fontObfuscationOnly)
        #expect(fontStatus.ready)
        #expect(fontStatus.unavailableReason == nil)

        let drm = try Fixture(contentAvailable: true, encryption: .unsupported)
        defer { drm.remove() }
        let drmStatus = try drm.runJSON(
            ContentStatusResult.self,
            arguments: ["content", "status", "12"]
        )
        #expect(drmStatus.materialization == .available)
        #expect(drmStatus.encryption == .contentEncryptionUnsupported)
        #expect(drmStatus.ready == false)
        #expect(drmStatus.unavailableReason == .contentEncryptionUnsupported)

        let metadataCapture = Capture()
        let metadataCode = CLIEntrypoint.run(
            arguments: ["content", "metadata", "12"] + drm.globalArguments + ["--json"],
            output: metadataCapture.output
        )
        #expect(metadataCode == CLIProcessExit.unavailable.rawValue)
        let envelope = try drm.decode(CLIErrorEnvelope.self, metadataCapture.stdout)
        #expect(envelope.error.code == .unavailable)
        #expect(metadataCapture.stderr.isEmpty)
    }

    @Test
    func metadataKeepsDatabaseIdentitySeparateFromRawEPUBAndCoreEnrichment() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }

        let result = try fixture.runJSON(
            ContentMetadataResult.self,
            arguments: ["content", "metadata", "12"]
        )
        #expect(result.source == .current)
        #expect(result.database.localPK == 1)
        #expect(result.database.assetID == "12")
        #expect(result.database.title == "DB Title")
        #expect(result.database.author == "DB Author")
        #expect(result.database.language == "db-lang")
        #expect(result.database.releaseDate != nil)
        #expect(result.epub.title == "EPUB Title")
        #expect(result.epub.creator == "EPUB Author")
        #expect(result.epub.language == "epub-lang")
        #expect(result.epub.publisher == "EPUB Publisher")
        #expect(result.enrichment.language == nil)
        #expect(result.enrichment.publicationDate == nil)
        #expect(result.enrichment.publisher == "EPUB Publisher")
    }

    @Test
    func coverWritesOnlyToExplicitAtomicFileAndNeverEmitsBinaryOrPath() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let destination = outputDirectory.appendingPathComponent("cover.bin")

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "cover", "12", "--output", destination.path] + fixture.globalArguments + ["--json"],
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains(destination.path) == false)
        #expect(capture.stdout.contains(fixture.coverData.base64EncodedString()) == false)
        let result = try fixture.decode(ContentCoverResult.self, capture.stdout)
        #expect(result.bookAssetID == "12")
        #expect(result.contentSource == .current)
        #expect(result.coverSource == .manifestProperty)
        #expect(result.mediaType == "image/png")
        #expect(result.byteCount == fixture.coverData.count)
        #expect(result.outputStatus == .created)
        #expect(try Data(contentsOf: destination) == fixture.coverData)

        let second = Capture()
        let secondCode = CLIEntrypoint.run(
            arguments: ["content", "cover", "12", "--output", destination.path] + fixture.globalArguments + ["--json"],
            output: second.output
        )
        #expect(secondCode == CLIProcessExit.writeSafety.rawValue)
        let envelope = try fixture.decode(CLIErrorEnvelope.self, second.stdout)
        #expect(envelope.error.code == .writeSafety)
        #expect(second.stdout.contains(destination.path) == false)
        #expect(try Data(contentsOf: destination) == fixture.coverData)
    }

    @Test
    func locateReturnsRawCFIRangeAndResolvedChapterWithoutInventingIdentity() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        let rawCFI = "epubcfi(/6/2[chapter]!/4/2,:4,:8)"

        let byAsset = try fixture.runJSON(
            ContentLocationResult.self,
            arguments: ["content", "locate", "12", rawCFI]
        )
        #expect(byAsset.rawCFI == rawCFI)
        #expect(byAsset.chapterID == "chapter")
        #expect(byAsset.characterRange == .init(start: 4, end: 8))
        #expect(byAsset.source == .current)
        #expect(byAsset.resolvedChapter?.id == "chapter")

        let byPK = try fixture.runJSON(
            ContentLocationResult.self,
            arguments: ["content", "locate", "--pk", "1", rawCFI]
        )
        #expect(byPK.bookAssetID == "12")
        #expect(byPK.rawCFI == rawCFI)

        let human = Capture()
        let humanCode = CLIEntrypoint.run(
            arguments: ["content", "locate", "12", rawCFI] + fixture.globalArguments,
            output: human.output
        )
        #expect(humanCode == CLIProcessExit.success.rawValue)
        #expect(human.stderr.isEmpty)
        #expect(human.stdout.contains(rawCFI) == false)
    }

    @Test
    func malformedCFIRemainsDiagnosticOnlyEvenWhenContentIsUnavailable() throws {
        let fixture = try Fixture(contentAvailable: false)
        defer { fixture.remove() }

        let result = try fixture.runJSON(
            ContentLocationResult.self,
            arguments: ["content", "locate", "12", "not-a-cfi"]
        )
        #expect(result.rawCFI == "not-a-cfi")
        #expect(result.chapterID == nil)
        #expect(result.characterRange == nil)
        #expect(result.source == nil)
        #expect(result.resolvedChapter == nil)
    }

    @Test
    func invalidOutputAndLocateGrammarFailBeforeDatabaseAccess() throws {
        let missing = "/definitely/not-present/applebookscli-t7.sqlite"

        let outputCapture = Capture()
        let outputCode = CLIEntrypoint.run(
            arguments: [
                "content", "cover", "12", "--output", "relative.png",
                "--library-db", missing, "--annotations-db", missing, "--json",
            ],
            output: outputCapture.output
        )
        #expect(outputCode == CLIProcessExit.usageInvalid.rawValue)

        let locateCapture = Capture()
        let locateCode = CLIEntrypoint.run(
            arguments: [
                "content", "locate", "--pk", "1", "extra", "cfi",
                "--library-db", missing, "--annotations-db", missing, "--json",
            ],
            output: locateCapture.output
        )
        #expect(locateCode == CLIProcessExit.usageInvalid.rawValue)
    }

    private enum EncryptionMode {
        case none
        case fontObfuscation
        case unsupported
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
        let epub: URL
        let supplementalRoot: URL
        let coverData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])

        var globalArguments: [String] {
            [
                "--library-db", library.path,
                "--annotations-db", annotations.path,
                "--config", config.path,
            ]
        }

        init(
            contentAvailable: Bool,
            encryption: EncryptionMode = .none,
            supplementalAvailable: Bool = false
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            epub = root.appendingPathComponent("book.epub", isDirectory: true)
            supplementalRoot = root.appendingPathComponent("supplemental", isDirectory: true)
            try FileManager.default.createDirectory(at: supplementalRoot, withIntermediateDirectories: true)
            if supplementalAvailable {
                try Data("materialized supplemental candidate".utf8)
                    .write(to: supplementalRoot.appendingPathComponent("book.epub"))
            }
            if contentAvailable {
                try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
                try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                    .write(to: epub.appendingPathComponent("META-INF/container.xml"))
                try Data("""
                <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <metadata>
                    <dc:title>EPUB Title</dc:title>
                    <dc:creator>EPUB Author</dc:creator>
                    <dc:language>epub-lang</dc:language>
                    <dc:publisher>EPUB Publisher</dc:publisher>
                    <dc:date>2026-08-31</dc:date>
                  </metadata>
                  <manifest>
                    <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                    <item id="cover" href="cover.png" media-type="image/jpeg" properties="cover-image"/>
                    <item id="font" href="font.ttf" media-type="font/ttf"/>
                  </manifest>
                  <spine><itemref idref="chapter"/></spine>
                </package>
                """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
                try coverData.write(to: epub.appendingPathComponent("OPS/cover.png"))
                if encryption != .none {
                    let algorithm = encryption == .fontObfuscation
                        ? "http://www.idpf.org/2008/embedding"
                        : "urn:synthetic:unsupported"
                    try Data("""
                    <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
                      <enc:EncryptedData>
                        <enc:EncryptionMethod Algorithm="\(algorithm)"/>
                        <enc:CipherData><enc:CipherReference URI="OPS/font.ttf"/></enc:CipherData>
                      </enc:EncryptedData>
                    </encryption>
                    """.utf8).write(to: epub.appendingPathComponent("META-INF/encryption.xml"))
                }
                // Intentionally no chapter.xhtml/font.ttf: inspect commands must not read chapter/font bodies.
            }

            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(library, sql: Self.librarySQL(epubPath: epub.path))
            try Self.createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
            let configuration = try JSONSerialization.data(
                withJSONObject: ["epub_root": supplementalRoot.path],
                options: [.sortedKeys]
            )
            try configuration.write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globalArguments + ["--json"], output: capture.output)
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

        private static func librarySQL(epubPath: String) -> String {
            let escaped = epubPath.replacingOccurrences(of: "'", with: "''")
            return """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZAUTHOR TEXT,
              ZPATH TEXT,
              ZLANGUAGE TEXT,
              ZRELEASEDATE REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES (1,'12','DB Title','DB Author','\(escaped)','db-lang',123);
            """
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

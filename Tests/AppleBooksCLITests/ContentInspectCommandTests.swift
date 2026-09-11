import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ContentInspectCommandTests")
struct ContentInspectCommandTests {
    @Test
    func metadataAllowsFontObfuscationAndRejectsUnsupportedDRMWithoutReadingChapterBody() throws {
        let font = try Fixture(contentAvailable: true, encryption: .fontObfuscation)
        defer { font.remove() }
        let fontMetadata = try font.runJSON(
            ContentMetadataResult.self,
            arguments: ["content", "metadata", "12"]
        )
        #expect(fontMetadata.bookAssetID == "12")

        let drm = try Fixture(contentAvailable: true, encryption: .unsupported)
        defer { drm.remove() }
        let metadataCapture = Capture()
        let metadataCode = CLIEntrypoint.run(
            arguments: ["content", "metadata", "12"] + drm.globalArguments,
            output: metadataCapture.output
        )
        #expect(metadataCode == CLIProcessExit.unavailable.rawValue)
        #expect(metadataCapture.stdout.isEmpty)
        let envelope = try drm.decode(CLIErrorEnvelope.self, metadataCapture.stderr)
        #expect(envelope.error.code == .unavailable)
    }

    @Test
    func metadataReturnsOneResolvedBoundedViewWithStableIdentityFirst() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "metadata", "12"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let result = try fixture.decode(ContentMetadataResult.self, capture.stdout)
        #expect(result.bookAssetID == "12")
        #expect(result.bookLocalPK == nil)
        #expect(result.contentSource == .current)
        #expect(result.title == "DB Title")
        #expect(result.author == "DB Author")
        #expect(result.language == "db-lang")
        #expect(result.publisher == "EPUB Publisher")
        #expect(result.publicationDate != nil)
        #expect(result.truncatedFields.isEmpty)
        #expect(capture.stdout.contains("\"database\"") == false)
        #expect(capture.stdout.contains("\"epub\"") == false)
        #expect(capture.stdout.contains("\"enrichment\"") == false)
        #expect(capture.stdout.contains("\"identifiers\"") == false)
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
            arguments: ["content", "cover", "12", "--output", destination.path] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains(fixture.coverData.base64EncodedString()) == false)
        let result = try fixture.decode(ContentCoverResult.self, capture.stdout)
        #expect(result.bookAssetID == "12")
        #expect(result.bookLocalPK == nil)
        #expect(result.contentSource == .current)
        #expect(result.coverSource == .manifestProperty)
        #expect(result.mediaType == "image/png")
        #expect(result.byteCount == fixture.coverData.count)
        #expect(result.destination == destination.standardizedFileURL.path)
        #expect(result.disposition == .created)
        #expect(try Data(contentsOf: destination) == fixture.coverData)

        let second = Capture()
        let secondCode = CLIEntrypoint.run(
            arguments: ["content", "cover", "12", "--output", destination.path] + fixture.globalArguments,
            output: second.output
        )
        #expect(secondCode == CLIProcessExit.writeSafety.rawValue)
        #expect(second.stdout.isEmpty)
        let envelope = try fixture.decode(CLIErrorEnvelope.self, second.stderr)
        #expect(envelope.error.code == .writeSafety)
        #expect(envelope.error.reason == "output_exists")
        #expect(second.stderr.contains(destination.path) == false)
        #expect(try Data(contentsOf: destination) == fixture.coverData)
    }

    @Test
    func metadataBoundsResolvedFieldsAndSubjectList() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        try fixture.clearDatabaseMetadata()

        let longTitle = String(repeating: "T", count: 600)
        let longAuthor = String(repeating: "A", count: 600)
        let longLanguage = String(repeating: "l", count: 160)
        let longPublisher = String(repeating: "P", count: 600)
        let longDate = String(repeating: "2", count: 160)
        let longRights = String(repeating: "R", count: 4_100)
        let longSubject = String(repeating: "S", count: 300)
        let subjects = [longSubject] + (1...32).map { "subject-\($0)" }
        try fixture.writePackageMetadata(
            title: longTitle,
            creator: longAuthor,
            isbn: "9780306406157",
            language: longLanguage,
            publisher: longPublisher,
            publicationDate: longDate,
            rights: longRights,
            subjects: subjects
        )

        let result = try fixture.runJSON(
            ContentMetadataResult.self,
            arguments: ["content", "metadata", "12"]
        )
        #expect(result.title?.count == 512)
        #expect(result.author?.count == 512)
        #expect(result.isbn == "9780306406157")
        #expect(result.language?.count == 128)
        #expect(result.publisher?.count == 512)
        #expect(result.publicationDate?.count == 128)
        #expect(result.rights?.count == 4_000)
        #expect(result.subjects.count == 32)
        #expect(result.subjects.first?.count == 256)
        #expect(result.truncatedFields == [
            "author", "language", "publicationDate", "publisher", "rights", "subjects", "title",
        ])
    }

    @Test
    func metadataAndCoverUseLocalPKFallbackWhenStableIdentityIsNotPublic() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        try fixture.setLibraryAssetID(String(repeating: "a", count: 2_049))

        let metadata = try fixture.runJSON(
            ContentMetadataResult.self,
            arguments: ["content", "metadata", "--pk", "1"]
        )
        #expect(metadata.bookAssetID == nil)
        #expect(metadata.bookLocalPK == 1)

        let destination = fixture.root.appendingPathComponent("cover-pk-fallback.bin")
        let cover = try fixture.runJSON(
            ContentCoverResult.self,
            arguments: ["content", "cover", "--pk", "1", "--output", destination.path]
        )
        #expect(cover.bookAssetID == nil)
        #expect(cover.bookLocalPK == 1)
    }

    @Test
    func coverResolvesRelativeOutputAgainstExplicitCurrentDirectory() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        let outputDirectory = fixture.root.appendingPathComponent("relative-output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let command = try ContentCoverCommand.parse(
            ["12", "--output", "cover-relative.bin"] + fixture.globalArguments
        )
        let result = try command.execute(currentDirectory: outputDirectory)
        let expected = outputDirectory.appendingPathComponent("cover-relative.bin").standardizedFileURL
        #expect(result.destination == expected.path)
        #expect(result.disposition == .created)
        #expect(try Data(contentsOf: expected) == fixture.coverData)
    }

    @Test
    func metadataAndCoverIgnoreBrokenAnnotationsDatabase() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        try fixture.corruptAnnotationsDatabase()

        let metadata = try fixture.runJSON(
            ContentMetadataResult.self,
            arguments: ["content", "metadata", "12"]
        )
        #expect(metadata.bookAssetID == "12")

        let destination = fixture.root.appendingPathComponent("cover-with-broken-annotations.bin")
        let cover = try fixture.runJSON(
            ContentCoverResult.self,
            arguments: ["content", "cover", "12", "--output", destination.path]
        )
        #expect(cover.destination == destination.standardizedFileURL.path)
        #expect(try Data(contentsOf: destination) == fixture.coverData)
    }

    @Test
    func metadataAndCoverFailClosedForOversizeOrInvalidDatabasePathsWithoutLeakingThem() throws {
        let fixture = try Fixture(contentAvailable: true)
        defer { fixture.remove() }
        let marker = "PRIVATE_PATH_MARKER_"
        func path(byteCount: Int) -> String {
            let prefix = "/\(marker)"
            let suffix = ".epub"
            return prefix + String(repeating: "x", count: byteCount - prefix.utf8.count - suffix.utf8.count) + suffix
        }
        let cases: [(String, String)] = [
            ("4096", path(byteCount: 4_096)),
            ("4097", path(byteCount: 4_097)),
            ("multi", path(byteCount: 2 * 1_024 * 1_024)),
            ("nul", "/\(marker)before\0after.epub"),
        ]

        for (label, rawPath) in cases {
            try fixture.setLibraryPath(rawPath)
            let metadataCapture = Capture()
            let metadataCode = CLIEntrypoint.run(
                arguments: ["content", "metadata", "12"] + fixture.globalArguments,
                output: metadataCapture.output
            )
            #expect(metadataCode == CLIProcessExit.unavailable.rawValue)
            #expect(metadataCapture.stdout.isEmpty)
            #expect(metadataCapture.stderr.contains(marker) == false)

            let destination = fixture.root.appendingPathComponent("rejected-\(label).bin")
            let coverCapture = Capture()
            let coverCode = CLIEntrypoint.run(
                arguments: ["content", "cover", "12", "--output", destination.path] + fixture.globalArguments,
                output: coverCapture.output
            )
            #expect(coverCode == CLIProcessExit.unavailable.rawValue)
            #expect(coverCapture.stdout.isEmpty)
            #expect(coverCapture.stderr.contains(marker) == false)
            #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        }
    }

    @Test
    func invalidOutputAndRemovedDiagnosticRoutesFailBeforeDatabaseAccess() throws {
        let missing = "/definitely/not-present/applebookscli-t7.sqlite"

        let outputCapture = Capture()
        let outputCode = CLIEntrypoint.run(
            arguments: [
                "content", "cover", "12", "--output", "",
                "--library-db", missing, "--annotations-db", missing,
            ],
            output: outputCapture.output
        )
        #expect(outputCode == CLIProcessExit.usageInvalid.rawValue)

        for arguments in [
            ["content", "status", "12"],
            ["content", "locate", "12", "epubcfi(/6/2)"],
            ["content", "current-chapter", "12"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
        }

        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["content", "--help"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stderr.isEmpty)
        let helpTokens = Set(help.stdout.split(whereSeparator: \.isWhitespace).map(String.init))
        for removed in ["status", "locate", "current-chapter"] {
            #expect(helpTokens.contains(removed) == false)
        }
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
            encryption: EncryptionMode = .none
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            epub = root.appendingPathComponent("book.epub", isDirectory: true)
            supplementalRoot = root.appendingPathComponent("supplemental", isDirectory: true)
            try FileManager.default.createDirectory(at: supplementalRoot, withIntermediateDirectories: true)
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

        func clearDatabaseMetadata() throws {
            try Self.execute(library, sql: "UPDATE ZBKLIBRARYASSET SET ZTITLE=NULL, ZAUTHOR=NULL, ZLANGUAGE=NULL, ZRELEASEDATE=NULL WHERE Z_PK=1;")
        }

        func writePackageMetadata(
            title: String,
            creator: String,
            isbn: String,
            language: String,
            publisher: String,
            publicationDate: String,
            rights: String,
            subjects: [String]
        ) throws {
            let subjectXML = subjects.map { "<dc:subject>\($0)</dc:subject>" }.joined()
            let document = """
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata>
                <dc:title>\(title)</dc:title>
                <dc:creator>\(creator)</dc:creator>
                <dc:identifier scheme="ISBN">\(isbn)</dc:identifier>
                <dc:language>\(language)</dc:language>
                <dc:publisher>\(publisher)</dc:publisher>
                <dc:date>\(publicationDate)</dc:date>
                <dc:rights>\(rights)</dc:rights>
                \(subjectXML)
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="cover.png" media-type="image/jpeg" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """
            try Data(document.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
        }

        func corruptAnnotationsDatabase() throws {
            try Data("not a sqlite database".utf8).write(to: annotations, options: .atomic)
        }

        func setLibraryPath(_ value: String) throws {
            try setLibraryText(column: "ZPATH", value: value)
        }

        func setLibraryAssetID(_ value: String) throws {
            try setLibraryText(column: "ZASSETID", value: value)
        }

        private func setLibraryText(column: String, value: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(library.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "UPDATE ZBKLIBRARYASSET SET \(column)=? WHERE Z_PK=1", -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bytes = Array(value.utf8)
            let bindResult = bytes.withUnsafeBytes { raw in
                sqlite3_bind_text(
                    statement,
                    1,
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(bytes.count),
                    transient
                )
            }
            guard bindResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, arguments: [String]) throws -> Value {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + globalArguments, output: capture.output)
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

        private static func execute(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
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

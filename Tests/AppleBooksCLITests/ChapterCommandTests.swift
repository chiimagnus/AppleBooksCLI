import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ChapterCommandTests")
struct ChapterCommandTests {
    @Test
    func chaptersPreserveNestedTOCIdentityFragmentsAndDepth() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try fixture.runJSON(
            ContentChaptersResult.self,
            arguments: ["content", "chapters", "12"]
        )
        #expect(result.bookLocalPK == 1)
        #expect(result.bookAssetID == "12")
        #expect(result.chapters.map(\.id) == ["1", "2", "chapter-two"])
        #expect(result.chapters.map(\.title) == ["One", "Two", "Three"])
        #expect(result.chapters.map(\.href) == [
            "OPS/Text/ch1.xhtml",
            "OPS/Text/ch1.xhtml",
            "OPS/Text/ch2.xhtml",
        ])
        #expect(result.chapters.map(\.fragment) == ["one", "two", ""])
        #expect(result.chapters.map(\.order) == [1, 2, 3])
        #expect(result.chapters.map(\.depth) == [0, 1, 1])

        let byPK = try fixture.runJSON(
            ContentChaptersResult.self,
            arguments: ["content", "chapters", "--pk", "1"]
        )
        #expect(byPK.chapters == result.chapters)
    }

    @Test
    func chapterUsesCoreSelectorOrderAndGraphemePagination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: [
                "content", "chapter", "12", "1",
                "--offset", "-100", "--max-chars", "2",
            ]
        )
        #expect(first.chapterSelector == "1")
        #expect(first.requestedOffset == -100)
        #expect(first.effectiveOffset == 0)
        #expect(first.content == "A🇸🇬")
        #expect(first.endOffset == 2)
        #expect(first.totalCharacters == 6)
        #expect(first.hasMore)
        #expect(first.nextOffset == 2)

        let byOrder = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "12", "3"]
        )
        #expect(byOrder.chapterSelector == "3")
        #expect(byOrder.content == "Second chapter body")
        #expect(byOrder.requestedOffset == 0)
        #expect(byOrder.effectiveOffset == 0)
        #expect(byOrder.endOffset == byOrder.content.count)
        #expect(byOrder.totalCharacters == byOrder.content.count)
        #expect(byOrder.hasMore == false)
        #expect(byOrder.nextOffset == nil)

        let rawSpineID = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--pk", "1", "appendix"]
        )
        #expect(rawSpineID.chapterSelector == "appendix")
        #expect(rawSpineID.content == "Appendix body")
        #expect(rawSpineID.hasMore == false)
    }

    @Test
    func invalidChapterInputFailsBeforeIOAndStableErrorsNeverEchoSelectors() throws {
        let missing = "/definitely/not-present/applebookscli-t8.sqlite"
        let missingGlobals = [
            "--library-db", missing,
            "--annotations-db", missing,
            "--json",
        ]

        let maxCapture = Capture()
        let maxCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "12", "1", "--max-chars", "0"] + missingGlobals,
            output: maxCapture.output
        )
        #expect(maxCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(maxCapture.stderr.isEmpty)
        #expect(maxCapture.stdout.contains("usage_invalid"))
        #expect(maxCapture.stdout.contains("Database override") == false)

        let negativeMaxCapture = Capture()
        let negativeMaxCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "12", "1", "--max-chars", "-1"] + missingGlobals,
            output: negativeMaxCapture.output
        )
        #expect(negativeMaxCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(negativeMaxCapture.stderr.isEmpty)
        #expect(negativeMaxCapture.stdout.contains("--max-chars must be greater than zero."))
        #expect(negativeMaxCapture.stdout.contains("Database override") == false)

        let grammarCapture = Capture()
        let grammarCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "--pk", "1", "one", "extra"] + missingGlobals,
            output: grammarCapture.output
        )
        #expect(grammarCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(grammarCapture.stderr.isEmpty)
        #expect(grammarCapture.stdout.contains("Database override") == false)

        let fixture = try Fixture()
        defer { fixture.remove() }

        let rangeCapture = Capture()
        let rangeCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "12", "1", "--offset", "6"] + fixture.globalArguments + ["--json"],
            output: rangeCapture.output
        )
        #expect(rangeCode == CLIProcessExit.usageInvalid.rawValue)
        let rangeEnvelope = try fixture.decode(CLIErrorEnvelope.self, rangeCapture.stdout)
        #expect(rangeEnvelope.error.code == .usageInvalid)
        #expect(rangeEnvelope.error.message == "Chapter offset is out of range.")

        let secretSelector = "private-selector-that-must-not-be-reflected"
        let missingCapture = Capture()
        let missingCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "12", secretSelector] + fixture.globalArguments + ["--json"],
            output: missingCapture.output
        )
        #expect(missingCode == CLIProcessExit.notFound.rawValue)
        let missingEnvelope = try fixture.decode(CLIErrorEnvelope.self, missingCapture.stdout)
        #expect(missingEnvelope.error.code == .notFound)
        #expect(missingEnvelope.error.message == "Chapter not found.")
        #expect(missingCapture.stdout.contains(secretSelector) == false)
    }

    @Test
    func currentChapterUsesOnlyTypeThreeBookmarkWithoutRecentAnnotationFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let current = try fixture.runJSON(
            ContentCurrentChapterResult.self,
            arguments: ["content", "current-chapter", "12"]
        )
        #expect(current.bookLocalPK == 1)
        #expect(current.bookAssetID == "12")
        #expect(current.chapter.id == "1")
        #expect(current.chapter.title == "One")
        #expect(current.chapter.fragment == "one")

        let inferredPosition = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "fallback-only"]
        )
        #expect(inferredPosition.source == .recentAnnotationInference)
        #expect(inferredPosition.chapterID == "chapter-two")

        let fallbackCapture = Capture()
        let fallbackCode = CLIEntrypoint.run(
            arguments: ["content", "current-chapter", "fallback-only"] + fixture.globalArguments + ["--json"],
            output: fallbackCapture.output
        )
        #expect(fallbackCode == CLIProcessExit.unavailable.rawValue)
        let envelope = try fixture.decode(CLIErrorEnvelope.self, fallbackCapture.stdout)
        #expect(envelope.error.code == .unavailable)
        #expect(envelope.error.message == "Current reading chapter is unavailable.")
        #expect(fallbackCapture.stderr.isEmpty)
    }

    @Test
    func explicitHumanChapterOutputMayContainBodyWhileDiagnosticsStayOnSuccessPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "chapter", "12", "3"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("Second chapter body"))
        #expect(capture.stdout.contains("effective offset: 0"))
    }

    private final class Fixture {
        let root: URL
        let epub: URL
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
            epub = root.appendingPathComponent("chapters.epub", isDirectory: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.makeEPUB(at: epub)
            try Self.createDatabase(library, sql: Self.librarySQL(epubPath: epub.path))
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
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(text.utf8))
        }

        private static func makeEPUB(at epub: URL) throws {
            try FileManager.default.createDirectory(
                at: epub.appendingPathComponent("META-INF", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: epub.appendingPathComponent("OPS/Text", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8).write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter-one" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="chapter-two" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="appendix" href="Text/appendix.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="chapter-one"/>
                <itemref idref="chapter-two"/>
                <itemref idref="appendix"/>
              </spine>
            </package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("""
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
              <body>
                <nav epub:type="toc">
                  <ol>
                    <li><a href="Text/ch1.xhtml#one">One</a>
                      <ol>
                        <li><a href="Text/ch1.xhtml#two">Two</a></li>
                        <li><a href="Text/ch2.xhtml">Three</a></li>
                      </ol>
                    </li>
                  </ol>
                </nav>
              </body>
            </html>
            """.utf8).write(to: epub.appendingPathComponent("OPS/nav.xhtml"))
            try Data("""
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
              <p id="one">A🇸🇬e\u{301}中🙂Z</p>
              <p id="two">Second fragment</p>
            </body></html>
            """.utf8).write(to: epub.appendingPathComponent("OPS/Text/ch1.xhtml"))
            try Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Second chapter body</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/Text/ch2.xhtml"))
            try Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Appendix body</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/Text/appendix.xhtml"))
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
              ZPATH TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'12','Primary','Author','\(escaped)'),
              (2,'fallback-only','Fallback','Author','\(escaped)');
            """
        }

        private static let annotationSQL = """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONLOCATION TEXT,
          ZANNOTATIONCREATIONDATE REAL,
          ZANNOTATIONMODIFICATIONDATE REAL
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,0,3,'12','epubcfi(/6/2[1]!/4/2,:0,:0)',100,100),
          (2,0,1,'fallback-only','epubcfi(/6/2[chapter-two]!/4/2,:0,:0)',200,200);
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

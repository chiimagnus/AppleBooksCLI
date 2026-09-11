@testable import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ChapterCommandTests")
struct ChapterCommandTests {
    @Test
    func chaptersUseBoundedSummaryCursorAndEveryOrderFeedsCanonicalChapterRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        var page = try fixture.runJSON(
            ContentChaptersPageResult.self,
            arguments: ["content", "chapters", "--book", "12", "--limit", "40"]
        )
        #expect(page.bookAssetID == "12")
        #expect(page.bookLocalPK == nil)
        #expect(page.items.count == 40)
        #expect(page.items.prefix(3).map(\.chapterOrder) == [1, 2, 3])
        #expect(page.items.prefix(3).map(\.title) == ["One", "Two", "Three"])
        #expect(page.items.prefix(3).map(\.depth) == [0, 1, 1])

        var allItems = page.items
        while let cursor = page.nextCursor {
            page = try fixture.runJSON(
                ContentChaptersPageResult.self,
                arguments: ["content", "chapters", "--book", "12", "--limit", "37", "--cursor", cursor]
            )
            allItems += page.items
        }
        #expect(page.hasMore == false)
        #expect(allItems.count == 105)
        #expect(allItems.map(\.chapterOrder) == Array(1...105))
        #expect(Set(allItems.map(\.chapterOrder)).count == 105)
        let longTitle = try #require(allItems.first(where: { $0.chapterOrder == 105 }))
        #expect(longTitle.title.count == 512)
        #expect(longTitle.truncatedFields == ["title"])

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "chapters", "--book", "12", "--limit", "1"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        let json = try #require(JSONSerialization.jsonObject(with: Data(capture.stdout.utf8)) as? [String: Any])
        let items = try #require(json["items"] as? [[String: Any]])
        let firstJSON = try #require(items.first)
        #expect(Set(firstJSON.keys) == Set(["chapterOrder", "title", "depth", "truncatedFields"]))
        for hidden in ["id", "href", "fragment", "order"] {
            #expect(firstJSON[hidden] == nil)
        }

        let byPK = try fixture.runJSON(
            ContentChaptersPageResult.self,
            arguments: ["content", "chapters", "--book-pk", "1", "--limit", "3"]
        )
        #expect(byPK.bookAssetID == "12")
        #expect(byPK.bookLocalPK == nil)
        #expect(byPK.items.map(\.chapterOrder) == [1, 2, 3])

        for order in 1...105 {
            let body = try fixture.runJSON(
                ContentChapterPageResult.self,
                arguments: ["content", "chapter", "--book", "12", "--chapter", String(order), "--max-chars", "1"]
            )
            #expect(body.chapterOrder == order)
            #expect(body.content.isEmpty == false)
        }
    }

    @Test
    func chaptersCursorBindsSelectorAndStalesWhenNavigationChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.runJSON(
            ContentChaptersPageResult.self,
            arguments: ["content", "chapters", "--book", "12", "--limit", "2"]
        )
        let cursor = try #require(first.nextCursor)

        let mismatch = Capture()
        let mismatchCode = CLIEntrypoint.run(
            arguments: ["content", "chapters", "--book-pk", "1", "--cursor", cursor] + fixture.globalArguments,
            output: mismatch.output
        )
        #expect(mismatchCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(mismatch.stdout.isEmpty)

        try fixture.replaceNavigationTitle()
        let stale = Capture()
        let staleCode = CLIEntrypoint.run(
            arguments: ["content", "chapters", "--book", "12", "--cursor", cursor] + fixture.globalArguments,
            output: stale.output
        )
        #expect(staleCode == CLIProcessExit.unavailable.rawValue)
        #expect(stale.stdout.isEmpty)
        #expect(try fixture.decode(CLIErrorEnvelope.self, stale.stderr).error.message == "Pagination cursor is stale. Restart from the first page.")

        let restarted = try fixture.runJSON(
            ContentChaptersPageResult.self,
            arguments: ["content", "chapters", "--book", "12", "--limit", "4"]
        )
        #expect(restarted.items.map(\.chapterOrder) == [1, 2, 3, 4])
        #expect(restarted.items.last?.title == "Changed Extra 4")
    }

    @Test
    func chapterUsesExactOrderStableIdentityAndOpaqueCursorPagination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: [
                "content", "chapter", "--book", "12", "--chapter", "1", "--max-chars", "2",
            ]
        )
        #expect(first.bookAssetID == "12")
        #expect(first.bookLocalPK == nil)
        #expect(first.chapterOrder == 1)
        #expect(first.content == "A🇸🇬")
        #expect(first.hasMore)
        let firstCursor = try #require(first.nextCursor)

        let second = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: [
                "content", "chapter", "--book", "12", "--chapter", "1",
                "--max-chars", "2", "--cursor", firstCursor,
            ]
        )
        #expect(second.content == "e\u{301}中")
        #expect(second.hasMore)
        let secondCursor = try #require(second.nextCursor)

        let third = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: [
                "content", "chapter", "--book", "12", "--chapter", "1",
                "--max-chars", "2", "--cursor", secondCursor,
            ]
        )
        #expect(third.content == "🙂Z")
        #expect(third.hasMore == false)
        #expect(third.nextCursor == nil)
        #expect(first.content + second.content + third.content == "A🇸🇬e\u{301}中🙂Z")

        let byOrder = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--book", "12", "--chapter", "3"]
        )
        #expect(byOrder.chapterOrder == 3)
        #expect(byOrder.content == "Second chapter body")
        #expect(byOrder.hasMore == false)
        #expect(byOrder.nextCursor == nil)

        let byPK = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--book-pk", "1", "--chapter", "3"]
        )
        #expect(byPK.bookAssetID == "12")
        #expect(byPK.bookLocalPK == nil)
        #expect(byPK.content == "Second chapter body")

        let orderConflict = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--book", "order-conflict", "--chapter", "2"]
        )
        #expect(orderConflict.chapterOrder == 2)
        #expect(orderConflict.content == "order two")

        let fallbackIdentity = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--book-pk", "4", "--chapter", "3"]
        )
        #expect(fallbackIdentity.bookAssetID == nil)
        #expect(fallbackIdentity.bookLocalPK == 4)
    }

    @Test
    func chapterCursorBindsSelectorAndOrderAndStalesWhenDirectoryResourceChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: ["content", "chapter", "--book", "12", "--chapter", "1", "--max-chars", "2"]
        )
        let cursor = try #require(first.nextCursor)

        for arguments in [
            ["content", "chapter", "--book", "12", "--chapter", "3", "--cursor", cursor],
            ["content", "chapter", "--book-pk", "1", "--chapter", "1", "--cursor", cursor],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + fixture.globalArguments, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
        }

        try fixture.replaceChapterOne(with: "changed chapter body with a different size")
        let stale = Capture()
        let staleCode = CLIEntrypoint.run(
            arguments: [
                "content", "chapter", "--book", "12", "--chapter", "1",
                "--max-chars", "2", "--cursor", cursor,
            ] + fixture.globalArguments,
            output: stale.output
        )
        #expect(staleCode == CLIProcessExit.unavailable.rawValue)
        #expect(stale.stdout.isEmpty)
        let envelope = try fixture.decode(CLIErrorEnvelope.self, stale.stderr)
        #expect(envelope.error.message == "Pagination cursor is stale. Restart from the first page.")
    }

    @Test
    func canonicalChapterUsesBoundedResourceTargetForDatabasePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.insertBook(localPK: 10, assetID: "path-4096", path: String(repeating: "x", count: 4_096))
        try fixture.insertBook(localPK: 11, assetID: "path-4097", path: String(repeating: "y", count: 4_097))
        try fixture.insertBook(localPK: 12, assetID: "path-huge", path: String(repeating: "z", count: 2 * 1_024 * 1_024))

        for assetID in ["path-4096", "path-4097", "path-huge"] {
            for command in [
                ["content", "chapter", "--book", assetID, "--chapter", "1"],
                ["content", "chapters", "--book", assetID],
            ] {
                let capture = Capture()
                let code = CLIEntrypoint.run(
                    arguments: command + fixture.globalArguments,
                    output: capture.output
                )
                #expect(code == CLIProcessExit.unavailable.rawValue)
                #expect(capture.stdout.isEmpty)
                #expect(capture.stderr.contains(String(repeating: "z", count: 128)) == false)
                #expect(capture.stderr.contains(String(repeating: "y", count: 128)) == false)
            }
        }
    }

    @Test
    func invalidChapterInputAndLegacyGrammarFailBeforeIO() throws {
        let missing = "/definitely/not-present/applebookscli-t10.sqlite"
        let missingGlobals = [
            "--library-db", missing,
            "--annotations-db", missing,
        ]
        let invalidCases: [[String]] = [
            ["content", "chapter", "--book", "12", "--chapter", "0"],
            ["content", "chapter", "--book", "12", "--chapter", "1", "--max-chars", "0"],
            ["content", "chapter", "--book", "12", "--chapter", "1", "--max-chars", "16001"],
            ["content", "chapter", "--book", "12", "--chapter", "1", "--cursor", "!"],
            ["content", "chapter", "--chapter", "1"],
            ["content", "chapter", "--book", "12", "--book-pk", "1", "--chapter", "1"],
            ["content", "chapter", "12", "1"],
            ["content", "chapter", "--book", "12", "--chapter", "1", "--offset", "1"],
            ["content", "chapters", "--book", "12", "--limit", "0"],
            ["content", "chapters", "--book", "12", "--limit", "101"],
            ["content", "chapters", "--book", "12", "--cursor", "!"],
            ["content", "chapters"],
            ["content", "chapters", "--book", "12", "--book-pk", "1"],
            ["content", "chapters", "12"],
            ["content", "chapters", "--book", "12", "--offset", "1"],
        ]
        for arguments in invalidCases {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
            #expect(capture.stderr.contains(missing) == false)
        }

        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["content", "chapter", "--help"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stderr.isEmpty)
        for flag in ["--book", "--book-pk", "--chapter", "--max-chars", "--cursor"] {
            #expect(help.stdout.contains(flag))
        }
        #expect(help.stdout.contains("--offset") == false)
        #expect(help.stdout.contains("ARGUMENTS:") == false)

        let chaptersHelp = Capture()
        let chaptersHelpCode = CLIEntrypoint.run(arguments: ["content", "chapters", "--help"], output: chaptersHelp.output)
        #expect(chaptersHelpCode == CLIProcessExit.success.rawValue)
        #expect(chaptersHelp.stderr.isEmpty)
        for flag in ["--book", "--book-pk", "--limit", "--cursor"] {
            #expect(chaptersHelp.stdout.contains(flag))
        }
        #expect(chaptersHelp.stdout.contains("--offset") == false)
        #expect(chaptersHelp.stdout.contains("ARGUMENTS:") == false)

        let fixture = try Fixture()
        defer { fixture.remove() }
        let missingChapter = Capture()
        let missingCode = CLIEntrypoint.run(
            arguments: ["content", "chapter", "--book", "12", "--chapter", "999"] + fixture.globalArguments,
            output: missingChapter.output
        )
        #expect(missingCode == CLIProcessExit.notFound.rawValue)
        #expect(missingChapter.stdout.isEmpty)
        let missingEnvelope = try fixture.decode(CLIErrorEnvelope.self, missingChapter.stderr)
        #expect(missingEnvelope.error.message == "Chapter not found.")
    }

    @Test
    func readingPositionChapterOrderFeedsCanonicalChapterAndNumericRawIDIsNotOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let position = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "order-conflict"]
        )
        #expect(position.bookAssetID == "order-conflict")
        #expect(position.bookLocalPK == nil)
        #expect(position.chapterOrder == 1)
        #expect(position.totalChapters == 2)

        let chapter = try fixture.runJSON(
            ContentChapterPageResult.self,
            arguments: [
                "content", "chapter", "--book", "order-conflict",
                "--chapter", String(position.chapterOrder),
            ]
        )
        #expect(chapter.chapterOrder == 1)
        #expect(chapter.content == "raw numeric id")
    }

    @Test
    func chapterDefaultsToJSONAndKeepsOnlyCanonicalContinuationFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["content", "chapter", "--book", "12", "--chapter", "3"] + fixture.globalArguments,
            output: capture.output
        )
        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let result = try fixture.decode(ContentChapterPageResult.self, capture.stdout)
        #expect(result.content == "Second chapter body")
        #expect(result.chapterOrder == 3)
        #expect(result.bookAssetID == "12")
        #expect(result.bookLocalPK == nil)

        let json = try #require(JSONSerialization.jsonObject(with: Data(capture.stdout.utf8)) as? [String: Any])
        for removed in ["chapterSelector", "requestedOffset", "effectiveOffset", "endOffset", "totalCharacters", "nextOffset", "href", "fragment"] {
            #expect(json[removed] == nil)
        }
    }

    private final class Fixture {
        let root: URL
        let epub: URL
        let orderConflictEPUB: URL
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
            orderConflictEPUB = root.appendingPathComponent("order-conflict.epub", isDirectory: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.makeEPUB(at: epub)
            try Self.makeOrderConflictEPUB(at: orderConflictEPUB)
            try Self.createDatabase(
                library,
                sql: Self.librarySQL(epubPath: epub.path, orderConflictPath: orderConflictEPUB.path)
            )
            try Self.createDatabase(annotations, sql: Self.annotationSQL)
            try Data("{}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func replaceChapterOne(with body: String) throws {
            try Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p id=\"one\">\(body)</p><p id=\"two\">Second fragment</p></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/Text/ch1.xhtml"))
        }

        func replaceNavigationTitle() throws {
            let url = epub.appendingPathComponent("OPS/nav.xhtml")
            let original = try String(contentsOf: url, encoding: .utf8)
            let changed = original.replacingOccurrences(of: ">Extra 4<", with: ">Changed Extra 4<")
            guard changed != original else { throw FixtureError.epub }
            try Data(changed.utf8).write(to: url)
        }

        func insertBook(localPK: Int64, assetID: String, path: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(library.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "INSERT INTO ZBKLIBRARYASSET(Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZPATH) VALUES(?,?,NULL,NULL,?)",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement else { throw FixtureError.sqlite }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK else { throw FixtureError.sqlite }
            guard assetID.withCString({ sqlite3_bind_text(statement, 2, $0, -1, sqliteTransient) }) == SQLITE_OK else { throw FixtureError.sqlite }
            let pathResult = path.utf8CString.withUnsafeBufferPointer { buffer in
                sqlite3_bind_text(statement, 3, buffer.baseAddress, Int32(buffer.count - 1), sqliteTransient)
            }
            guard pathResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, arguments: [String]) throws -> Value {
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

            let longRawID = String(repeating: "raw-id-", count: 1_300)
            let package = """
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter-one" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="chapter-two" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
                <item id="appendix" href="Text/appendix.xhtml" media-type="application/xhtml+xml"/>
                <item id="\(longRawID)" href="Text/extras.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine>
                <itemref idref="chapter-one"/>
                <itemref idref="chapter-two"/>
                <itemref idref="appendix"/>
                <itemref idref="\(longRawID)"/>
              </spine>
            </package>
            """
            try Data(package.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))

            let extraLinks = (4...105).map { order -> String in
                let title = order == 105 ? String(repeating: "T", count: 700) : "Extra \(order)"
                return "<li><a href=\"Text/extras.xhtml#extra-\(order)\">\(title)</a></li>"
            }.joined()
            let navigation = """
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
                    \(extraLinks)
                  </ol>
                </nav>
              </body>
            </html>
            """
            try Data(navigation.utf8).write(to: epub.appendingPathComponent("OPS/nav.xhtml"))

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
            let extraBodies = (4...105).map { "<p id=\"extra-\($0)\">extra body \($0)</p>" }.joined()
            try Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\(extraBodies)</body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/Text/extras.xhtml"))
        }

        private static func makeOrderConflictEPUB(at epub: URL) throws {
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"2\" href=\"raw.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"target\" href=\"target.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"2\"/><itemref idref=\"target\"/></spine></package>".utf8)
                .write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>raw numeric id</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/raw.xhtml"))
            try Data("<html><body>order two</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/target.xhtml"))
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static func librarySQL(epubPath: String, orderConflictPath: String) -> String {
            let escaped = epubPath.replacingOccurrences(of: "'", with: "''")
            let conflictEscaped = orderConflictPath.replacingOccurrences(of: "'", with: "''")
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
              (2,'fallback-only','Fallback','Author','\(escaped)'),
              (3,'order-conflict','Conflict','Author','\(conflictEscaped)'),
              (4,NULL,'PK Fallback','Author','\(escaped)');
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
          (2,0,1,'fallback-only','epubcfi(/6/2[chapter-two]!/4/2,:0,:0)',200,200),
          (3,0,3,'order-conflict','epubcfi(/6/2[2]!/4/2,:0,:0)',300,300);
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
        case epub
    }
}

import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ReadingStatsCommandTests")
struct ReadingStatsCommandTests {
    @Test
    func statusCommandsPreserveCorePartitionsAsCursorPages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let inProgress = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "in-progress"]
        )
        #expect(inProgress.items.map(\.assetID) == ["12"])
        #expect(inProgress.items.first?.title == "Alpha")
        #expect(inProgress.items.first?.truncatedFields.isEmpty == true)
        #expect(inProgress.nextCursor == nil)
        #expect(inProgress.hasMore == false)

        let finished = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "finished"]
        )
        #expect(finished.items.map(\.assetID) == ["finished-id"])
        #expect(finished.items.first?.title == "Beta")

        let unstarted = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "unstarted"]
        )
        #expect(unstarted.items.map(\.assetID) == ["infer-id"])
        #expect(unstarted.items.first?.title == "Gamma")

        let recentDefault = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent"]
        )
        #expect(recentDefault.items.map(\.assetID) == ["finished-id", "12", "infer-id"])
        #expect(recentDefault.nextCursor == nil)
        #expect(recentDefault.hasMore == false)

        let recentFirst = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent", "--limit", "2"]
        )
        #expect(recentFirst.items.map(\.assetID) == ["finished-id", "12"])
        #expect(recentFirst.hasMore == true)
        let cursor = try #require(recentFirst.nextCursor)

        let recentSecond = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent", "--limit", "2", "--cursor", cursor]
        )
        #expect(recentSecond.items.map(\.assetID) == ["infer-id"])
        #expect(recentSecond.nextCursor == nil)
        #expect(recentSecond.hasMore == false)
    }

    @Test
    func nonFiniteProgressIsUnstartedAndCannotBreakReadingJSONOrStats() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeInferBookProgressNonFinite()

        let unstarted = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "unstarted"]
        )
        #expect(unstarted.items.map(\.assetID) == ["infer-id"])
        #expect(unstarted.items.first?.title == "Gamma")

        let recent = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent"]
        )
        #expect(recent.items.map(\.assetID) == ["finished-id", "12"])

        let stats = try fixture.runJSON(StatsResult.self, arguments: ["stats"])
        #expect(stats.finishedBooks == 1)
        #expect(stats.inProgressBooks == 1)
        #expect(stats.unstartedBooks == 1)
    }

    @Test
    func positionReturnsOnlyActionableBookmarkChapterAndRejectsHintOrInference() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let toc = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "12"]
        )
        #expect(toc.bookLocalPK == nil)
        #expect(toc.bookAssetID == "12")
        #expect(toc.chapterOrder == 1)
        #expect(toc.title == "Section 1")
        #expect(toc.totalChapters == 1)
        #expect(toc.truncatedFields.isEmpty)

        let byPK = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "--pk", "1"]
        )
        #expect(byPK.bookAssetID == "12")
        #expect(byPK.bookLocalPK == nil)
        #expect(byPK.chapterOrder == 1)

        let compactCapture = Capture()
        let compactCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "12"] + fixture.globalArguments,
            output: compactCapture.output
        )
        #expect(compactCode == CLIProcessExit.success.rawValue)
        let compact = try #require(JSONSerialization.jsonObject(with: Data(compactCapture.stdout.utf8)) as? [String: Any])
        #expect(compact["chapterOrder"] as? Int == 1)
        #expect(compact["chapterID"] == nil)
        #expect(compact["source"] == nil)
        #expect(compact["order"] == nil)

        for arguments in [
            ["reading", "position", "--pk", "2"],
            ["reading", "position", "infer-id"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + fixture.globalArguments, output: capture.output)
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try fixture.decode(CLIErrorEnvelope.self, capture.stderr)
            #expect(envelope.error.code == .unavailable)
            #expect(envelope.error.reason == "reading_position_unavailable")
            #expect(envelope.error.message == "Reading position is unavailable for this book.")
            #expect(capture.stderr.contains("outside") == false)
            #expect(capture.stderr.contains("epubcfi") == false)
        }
    }

    @Test
    func positionResultBoundsTitleAndUsesLocalPKOnlyAsIdentityFallback() {
        let result = ReadingPositionResult(SemanticBookmarkedReadingPosition(
            bookLocalPK: 7,
            bookAssetID: nil,
            chapterOrder: 3,
            title: String(repeating: "T", count: 700),
            totalChapters: 9
        ))
        #expect(result.bookAssetID == nil)
        #expect(result.bookLocalPK == 7)
        #expect(result.chapterOrder == 3)
        #expect(result.title.count == 512)
        #expect(result.totalChapters == 9)
        #expect(result.truncatedFields == ["title"])
    }

    @Test
    func positionUsesBoundedResourceTargetForDatabasePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let marker = "PRIVATE_READING_PATH_"
        func path(byteCount: Int) -> String {
            let prefix = "/\(marker)"
            let suffix = ".epub"
            return prefix + String(repeating: "x", count: byteCount - prefix.utf8.count - suffix.utf8.count) + suffix
        }

        for rawPath in [path(byteCount: 4_096), path(byteCount: 4_097), path(byteCount: 2 * 1_024 * 1_024)] {
            try fixture.setBookPath(assetID: "12", path: rawPath)
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["reading", "position", "12"] + fixture.globalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.unavailable.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(marker) == false)
        }
    }

    @Test
    func statsUseCoreAggregateWithoutRecomputingInCLI() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try fixture.runJSON(StatsResult.self, arguments: ["stats"])
        #expect(result.totalBooks == 3)
        #expect(result.finishedBooks == 1)
        #expect(result.inProgressBooks == 1)
        #expect(result.unstartedBooks == 1)
        #expect(result.totalUserAnnotations == 3)
        #expect(result.historicalAnnotationCount == 0)
        #expect(result.unmappedAnnotationCount == 1)
        #expect(result.ambiguousAnnotationCount == 0)
        #expect(result.identityUnavailableAnnotationCount == 0)
        #expect(result.topAnnotatedBooks.count == 2)
        #expect(Set(result.topAnnotatedBooks.compactMap(\.assetID)) == ["12", "infer-id"])
        #expect(result.topAnnotatedBooks.allSatisfy { $0.annotationCount == 1 })
    }

    @Test
    func invalidPaginationAndSelectorFailBeforeDatabaseAccess() {
        let missingGlobals = [
            "--library-db", "/definitely/missing/library.sqlite",
            "--annotations-db", "/definitely/missing/annotations.sqlite",
        ]

        let limitCapture = Capture()
        let limitCode = CLIEntrypoint.run(
            arguments: ["reading", "recent", "--limit", "0"] + missingGlobals,
            output: limitCapture.output
        )
        #expect(limitCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(limitCapture.stdout.isEmpty)
        #expect(limitCapture.stderr.contains("usage_invalid"))
        #expect(limitCapture.stderr.contains("Database override") == false)

        let offsetCapture = Capture()
        let offsetCode = CLIEntrypoint.run(
            arguments: ["reading", "recent", "--offset", "1"] + missingGlobals,
            output: offsetCapture.output
        )
        #expect(offsetCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(offsetCapture.stdout.isEmpty)
        #expect(offsetCapture.stderr.contains("usage_invalid"))
        #expect(offsetCapture.stderr.contains("Database override") == false)

        let selectorCapture = Capture()
        let selectorCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "12", "--pk", "2"] + missingGlobals,
            output: selectorCapture.output
        )
        #expect(selectorCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(selectorCapture.stdout.isEmpty)
        #expect(selectorCapture.stderr.contains("usage_invalid"))
        #expect(selectorCapture.stderr.contains("Database override") == false)
    }

    @Test
    func missingBookAndUnavailableContentUseStableSanitizedErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let missing = Capture()
        let missingCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "missing"] + fixture.globalArguments,
            output: missing.output
        )
        #expect(missingCode == CLIProcessExit.notFound.rawValue)
        #expect(missing.stdout.isEmpty)
        let missingEnvelope = try fixture.decode(CLIErrorEnvelope.self, missing.stderr)
        #expect(missingEnvelope.error.code == .notFound)
        #expect(missingEnvelope.error.message == "Book not found.")

        do {
            _ = try CLIOperation.run { () throws -> Void in
                throw ContentError.bookPathUnavailable
            }
            Issue.record("content failure should be translated")
        } catch let error as CLIError {
            #expect(error == .unavailable("Book content is unavailable."))
        }

        let malformed = try Fixture(epubHref: "../../escape.xhtml")
        defer { malformed.remove() }
        let malformedCapture = Capture()
        let malformedCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "12"] + malformed.globalArguments,
            output: malformedCapture.output
        )
        #expect(malformedCode == CLIProcessExit.unavailable.rawValue)
        #expect(malformedCapture.stdout.isEmpty)
        let malformedEnvelope = try malformed.decode(CLIErrorEnvelope.self, malformedCapture.stderr)
        #expect(malformedEnvelope.error.code == .unavailable)
        #expect(malformedEnvelope.error.message == "Book content is unavailable.")
    }

    @Test
    func statusAndStatsDefaultToJSONOnStdout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for arguments in [["reading", "finished"], ["stats"]] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: arguments + fixture.globalArguments,
                output: capture.output
            )
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect((try JSONSerialization.jsonObject(with: Data(capture.stdout.utf8))) is [String: Any])
        }
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
        let epub: URL

        var globalArguments: [String] {
            [
                "--library-db", library.path,
                "--annotations-db", annotations.path,
                "--config", config.path,
            ]
        }

        init(epubHref: String = "chapter.xhtml") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            epub = try Self.makeEPUB(in: root, chapterHref: epubHref)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try Self.createDatabase(library, sql: Self.librarySQL(epubPath: epub.path))
            try Self.createDatabase(annotations, sql: Self.annotationSQL)
            try Data("{}".utf8).write(to: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func setBookPath(assetID: String, path: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(library.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqliteOpen(open) }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(
                handle,
                "UPDATE ZBKLIBRARYASSET SET ZPATH = ? WHERE ZASSETID = ?",
                -1,
                &statement,
                nil
            )
            guard prepare == SQLITE_OK, let statement else { throw FixtureError.sqliteExec(prepare) }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let pathBytes = Array(path.utf8)
            let pathBind = pathBytes.withUnsafeBytes { raw in
                sqlite3_bind_text(
                    statement,
                    1,
                    raw.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(pathBytes.count),
                    transient
                )
            }
            guard pathBind == SQLITE_OK,
                  assetID.withCString({ sqlite3_bind_text(statement, 2, $0, -1, transient) }) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw FixtureError.sqliteExec(sqlite3_errcode(handle))
            }
        }

        func makeInferBookProgressNonFinite() throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(library.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw FixtureError.sqliteOpen(open)
            }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            let prepare = sqlite3_prepare_v2(
                handle,
                "UPDATE ZBKLIBRARYASSET SET ZREADINGPROGRESS = ?, ZLASTOPENDATE = ? WHERE ZASSETID = 'infer-id'",
                -1,
                &statement,
                nil
            )
            guard prepare == SQLITE_OK, let statement else {
                throw FixtureError.sqliteExec(prepare)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_double(statement, 1, .infinity) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, .infinity) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw FixtureError.sqliteExec(sqlite3_errcode(handle))
            }
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

        private static func makeEPUB(in parent: URL, chapterHref: String) throws -> URL {
            let root = parent.appendingPathComponent("book.epub", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("META-INF", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("OPS", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: root.appendingPathComponent("META-INF/container.xml"))
            let escapedHref = chapterHref.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"\(escapedHref)\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8)
                .write(to: root.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body><p>chapter</p></body></html>".utf8)
                .write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
            return root
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

        private static func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        private static func librarySQL(epubPath: String) -> String {
            """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZAUTHOR TEXT,
              ZPATH TEXT,
              ZISFINISHED INTEGER,
              ZREADINGPROGRESS REAL,
              ZDATEFINISHED REAL,
              ZLASTOPENDATE REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'12','Alpha','Ada','\(sql(epubPath))',0,0.5,NULL,200),
              (2,'finished-id','Beta','Bob','\(sql(epubPath))',1,1.0,400,300),
              (3,'infer-id','Gamma','Cara','\(sql(epubPath))',0,0.0,NULL,100);
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
          (1,0,3,'12','epubcfi(/6/2[chapter]!/4/2,:0,:0)',100,100),
          (2,0,3,'finished-id','epubcfi(/6/2[outside]!/4/2,:0,:0)',200,200),
          (3,0,1,'infer-id','epubcfi(/6/2[chapter]!/4/2,:0,:0)',300,300),
          (4,0,1,'12',NULL,50,50),
          (5,0,1,'orphan-id',NULL,60,60);
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

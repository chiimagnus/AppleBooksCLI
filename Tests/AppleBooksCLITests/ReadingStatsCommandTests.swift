import AppleBooksCore
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("ReadingStatsCommandTests")
struct ReadingStatsCommandTests {
    @Test
    func statusCommandsPreserveCorePartitionsRawProgressAndRecentDefault() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let inProgress = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "in-progress"]
        )
        #expect(inProgress.items.map(\.assetID) == ["12"])
        #expect(inProgress.items.first?.readingProgressRaw == 0.5)
        #expect(inProgress.items.first?.readingProgressPercent == 50)
        #expect(inProgress.limit == nil)

        let finished = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "finished"]
        )
        #expect(finished.items.map(\.assetID) == ["finished-id"])
        #expect(finished.items.first?.readingProgressRaw == 1)
        #expect(finished.items.first?.readingProgressPercent == 100)

        let unstarted = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "unstarted"]
        )
        #expect(unstarted.items.map(\.assetID) == ["infer-id"])
        #expect(unstarted.items.first?.readingProgressRaw == 0)
        #expect(unstarted.items.first?.readingProgressPercent == 0)

        let recentDefault = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent"]
        )
        #expect(recentDefault.limit == 10)
        #expect(recentDefault.items.map(\.assetID) == ["finished-id", "12", "infer-id"])

        let recentPage = try fixture.runJSON(
            ReadingBooksResult.self,
            arguments: ["reading", "recent", "--limit", "2", "--offset", "1"]
        )
        #expect(recentPage.limit == 2)
        #expect(recentPage.offset == 1)
        #expect(recentPage.items.map(\.assetID) == ["12", "infer-id"])
    }

    @Test
    func positionUsesSharedExactBookSelectorAndCanonicalCoreSourceValues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let toc = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "12"]
        )
        #expect(toc.bookLocalPK == 1)
        #expect(toc.bookAssetID == "12")
        #expect(toc.chapterID == "chapter")
        #expect(toc.title == "Section 1")
        #expect(toc.order == 1)
        #expect(toc.totalChapters == 1)
        #expect(toc.source == .bookmarkToc)

        let hint = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "--pk", "2"]
        )
        #expect(hint.bookLocalPK == 2)
        #expect(hint.chapterID == "outside")
        #expect(hint.title == nil)
        #expect(hint.source == .bookmarkHint)

        let inferred = try fixture.runJSON(
            ReadingPositionResult.self,
            arguments: ["reading", "position", "infer-id"]
        )
        #expect(inferred.bookLocalPK == 3)
        #expect(inferred.chapterID == "chapter")
        #expect(inferred.title == "Section 1")
        #expect(inferred.order == nil)
        #expect(inferred.totalChapters == nil)
        #expect(inferred.source == .recentAnnotationInference)
    }

    @Test
    func readingPositionSourceEncodesItsCanonicalCaseNameDirectly() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for source in [
            ReadingPositionSource.bookmarkToc,
            .bookmarkHint,
            .recentAnnotationInference,
        ] {
            let data = try encoder.encode(source)
            #expect(String(decoding: data, as: UTF8.self) == "\"\(source.rawValue)\"")
            #expect(try decoder.decode(ReadingPositionSource.self, from: data) == source)
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
        #expect(result.orphanUserAnnotations == 1)
        #expect(result.topAnnotatedBooks.count == 2)
        #expect(Set(result.topAnnotatedBooks.compactMap(\.assetID)) == ["12", "infer-id"])
        #expect(result.topAnnotatedBooks.allSatisfy { $0.userAnnotationCount == 1 })
    }

    @Test
    func invalidPaginationAndSelectorFailBeforeDatabaseAccess() {
        let missingGlobals = [
            "--library-db", "/definitely/missing/library.sqlite",
            "--annotations-db", "/definitely/missing/annotations.sqlite",
            "--json",
        ]

        let limitCapture = Capture()
        let limitCode = CLIEntrypoint.run(
            arguments: ["reading", "recent", "--limit", "0"] + missingGlobals,
            output: limitCapture.output
        )
        #expect(limitCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(limitCapture.stderr.isEmpty)
        #expect(limitCapture.stdout.contains("usage_invalid"))
        #expect(limitCapture.stdout.contains("Database override") == false)

        let selectorCapture = Capture()
        let selectorCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "12", "--pk", "2"] + missingGlobals,
            output: selectorCapture.output
        )
        #expect(selectorCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(selectorCapture.stderr.isEmpty)
        #expect(selectorCapture.stdout.contains("usage_invalid"))
        #expect(selectorCapture.stdout.contains("Database override") == false)
    }

    @Test
    func missingBookAndUnavailableContentUseStableSanitizedErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let missing = Capture()
        let missingCode = CLIEntrypoint.run(
            arguments: ["reading", "position", "missing"] + fixture.globalArguments + ["--json"],
            output: missing.output
        )
        #expect(missingCode == CLIProcessExit.notFound.rawValue)
        let missingEnvelope = try fixture.decode(CLIErrorEnvelope.self, missing.stdout)
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
            arguments: ["reading", "position", "12"] + malformed.globalArguments + ["--json"],
            output: malformedCapture.output
        )
        #expect(malformedCode == CLIProcessExit.unavailable.rawValue)
        let malformedEnvelope = try malformed.decode(CLIErrorEnvelope.self, malformedCapture.stdout)
        #expect(malformedEnvelope.error.code == .unavailable)
        #expect(malformedEnvelope.error.message == "Book content is unavailable.")
        #expect(malformedCapture.stderr.isEmpty)
    }

    @Test
    func humanStatusAndStatsWriteOnlyToStdout() throws {
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
            #expect(capture.stdout.isEmpty == false)
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

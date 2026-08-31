import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ReadingPositionTests")
struct ReadingPositionTests {
    @Test
    func tocBookmarkReturnsExactChapterAndTotal() throws {
        let fixture = try makeFixture(annotationRows: """
        (1,0,3,'asset','epubcfi(/6/2[chapter]!/4/2,:0,:0)',100)
        """)
        defer { fixture.cleanup() }

        let position = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 1))
        #expect(position.source == .bookmarkToc)
        #expect(position.chapterID == "chapter")
        #expect(position.title == "Section 1")
        #expect(position.order == 1)
        #expect(position.totalChapters == 1)
    }

    @Test
    func bookmarkHintOutsideTocPreservesRawChapterIdentity() throws {
        let fixture = try makeFixture(annotationRows: """
        (1,0,3,'asset','epubcfi(/6/2[outside]!/4/2,:0,:0)',100)
        """)
        defer { fixture.cleanup() }

        let position = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 1))
        #expect(position == ReadingPosition(
            chapterID: "outside",
            title: nil,
            order: nil,
            totalChapters: nil,
            source: .bookmarkHint
        ))
    }

    @Test
    func recentUserAnnotationInferenceUsesCreationThenLocalPKAndCanEnrichTitle() throws {
        let fixture = try makeFixture(annotationRows: """
        (1,0,3,'asset',NULL,500),
        (10,0,1,'asset','epubcfi(/6/2[older]!/4/2,:0,:0)',200),
        (11,0,1,'asset','epubcfi(/6/2[unknown]!/4/2,:0,:0)',300),
        (12,0,1,'asset','epubcfi(/6/2[chapter]!/4/2,:0,:0)',300),
        (13,1,1,'asset','epubcfi(/6/2[deleted]!/4/2,:0,:0)',900),
        (14,0,3,'asset',NULL,900)
        """)
        defer { fixture.cleanup() }

        let position = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 1))
        #expect(position.source == .recentAnnotationInference)
        #expect(position.chapterID == "chapter")
        #expect(position.title == "Section 1")
        #expect(position.order == nil)
        #expect(position.totalChapters == nil)
    }

    @Test
    func inferredUnknownChapterKeepsOnlyIdentityAndNeverWritesBookmark() throws {
        let fixture = try makeFixture(annotationRows: """
        (20,0,1,'asset','epubcfi(/6/2[unknown]!/4/2,:0,:0)',400)
        """)
        defer { fixture.cleanup() }

        let position = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 1))
        #expect(position == ReadingPosition(
            chapterID: "unknown",
            title: nil,
            order: nil,
            totalChapters: nil,
            source: .recentAnnotationInference
        ))
        #expect(try fixture.books.currentReadingLocation(forBookLocalPK: 1) == nil)
    }

    @Test
    func noTierReturnsNilWhileContentErrorsRemainStructuredWhenResolutionNeedsContent() throws {
        let empty = try makeFixture(annotationRows: "")
        defer { empty.cleanup() }
        #expect(try empty.books.currentReadingPosition(forBookLocalPK: 1) == nil)

        let unavailable = try makeFixture(
            annotationRows: "(1,0,3,'asset','epubcfi(/6/2[chapter]!/4/2,:0,:0)',100)",
            includePath: false
        )
        defer { unavailable.cleanup() }
        #expect(throws: ContentError.bookPathUnavailable) {
            _ = try unavailable.books.currentReadingPosition(forBookLocalPK: 1)
        }
    }

    private func makeFixture(annotationRows: String, includePath: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let epub = try makeEPUB(in: root)
        let pathValue = includePath ? "'\(sql(epub.path))'" : "NULL"
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset',\(pathValue));
        """)
        let annotationsSQL = annotationRows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : "INSERT INTO ZAEANNOTATION VALUES \(annotationRows);"
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONLOCATION TEXT,
          ZANNOTATIONCREATIONDATE REAL
        );
        \(annotationsSQL)
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return Fixture(
            root: root,
            books: try AppleBooks(libraryDB: library, annotationsDB: annotations, historicalConfig: config)
        )
    }

    private func makeEPUB(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("book.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8)
            .write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body><p>chapter</p></body></html>".utf8)
            .write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
        return root
    }

    private func database(at url: URL, sql: String) throws -> URL {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
        return url
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private struct Fixture {
        let root: URL
        let books: AppleBooks

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

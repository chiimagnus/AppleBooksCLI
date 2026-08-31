import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CurrentReadingChapterTests")
struct CurrentReadingChapterTests {
    @Test
    func resolvesSpineChapterAndReturnsNilForMissingIdentityOrHint() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let normalEPUB = try makeEPUB(in: root, name: "normal", duplicateSpine: false)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'asset-1','\(sql(normalEPUB.path))'),
          (2,NULL,'/tmp/should-not-be-opened.epub'),
          (3,'asset-3',NULL);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONLOCATION TEXT,
          ZANNOTATIONMODIFICATIONDATE REAL
        );
        INSERT INTO ZAEANNOTATION VALUES
          (11,0,3,'asset-1','epubcfi(/6/2[chapter]!/4/2,:0,:0)',10),
          (12,0,3,'asset-3','epubcfi(/6/2!/4/2,:0,:0)',10);
        """)
        let books = try makeAppleBooks(library: library, annotations: annotations, root: root)

        let chapter = try #require(try books.currentReadingChapter(forBookLocalPK: 1))
        #expect(chapter.id == "chapter")
        #expect(chapter.order == 1)
        #expect(try books.currentReadingChapter(forBookLocalPK: 2) == nil)
        #expect(try books.currentReadingChapter(forBookLocalPK: 3) == nil)
    }

    @Test
    func bookmarkWithHintPropagatesMissingContentPath() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset-1',NULL);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONDELETED INTEGER,ZANNOTATIONTYPE INTEGER,ZANNOTATIONASSETID TEXT,ZANNOTATIONLOCATION TEXT);
        INSERT INTO ZAEANNOTATION VALUES (1,0,3,'asset-1','epubcfi(/6/2[chapter]!/4/2,:0,:0)');
        """)
        let books = try makeAppleBooks(library: library, annotations: annotations, root: root)

        #expect(throws: ContentError.bookPathUnavailable) {
            _ = try books.currentReadingChapter(forBookLocalPK: 1)
        }
    }

    @Test
    func duplicateSpineIDsFallBackToNumericOrderBeforeCurrentChapterMatch() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try makeEPUB(in: root, name: "duplicate", duplicateSpine: true)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset-1','\(sql(epub.path))');
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONDELETED INTEGER,ZANNOTATIONTYPE INTEGER,ZANNOTATIONASSETID TEXT,ZANNOTATIONLOCATION TEXT);
        INSERT INTO ZAEANNOTATION VALUES (1,0,3,'asset-1','epubcfi(/6/2[2]!/4/2,:0,:0)');
        """)
        let books = try makeAppleBooks(library: library, annotations: annotations, root: root)

        let chapter = try #require(try books.currentReadingChapter(forBookLocalPK: 1))
        #expect(chapter.id == "2")
        #expect(chapter.order == 2)
    }

    private func makeAppleBooks(library: URL, annotations: URL, root: URL) throws -> AppleBooks {
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return try AppleBooks(libraryDB: library, annotationsDB: annotations, historicalConfig: config)
    }

    private func makeEPUB(in parent: URL, name: String, duplicateSpine: Bool) throws -> URL {
        let root = parent.appendingPathComponent(name).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        let spine = duplicateSpine
            ? "<itemref idref=\"chapter\"/><itemref idref=\"chapter\"/>"
            : "<itemref idref=\"chapter\"/>"
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine>\(spine)</spine></package>".utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body>chapter</body></html>".utf8).write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
        return root
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func database(at url: URL, sql: String) throws -> URL {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else { throw SQLiteError.current(operation: .open, code: open, handle: handle) }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw SQLiteError.current(operation: .step, code: result, handle: handle) }
        return url
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

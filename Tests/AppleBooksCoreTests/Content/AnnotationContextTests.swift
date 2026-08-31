import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationContextTests")
struct AnnotationContextTests {
    @Test
    func locatesFlexibleWhitespaceMatchAndPreservesExactCanonicalSpan() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let context = try fixture.books.annotationContext(localPK: 1, charsBefore: 8, charsAfter: 8)
        #expect(context.matched == "quick\n\nbrown")
        #expect(context.before.hasSuffix("The "))
        #expect(context.after.hasPrefix(" fox"))
        #expect(context.leadingTruncated)
        #expect(context.trailingTruncated)
        #expect(context.text.contains("quick\n\nbrown"))
    }

    @Test
    func emptySelectedTextFallsBackToRepresentativeText() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let context = try fixture.books.annotationContext(localPK: 2, charsBefore: 20, charsAfter: 20)
        #expect(context.matched == "brown fox")
    }

    @Test
    func currentBookIdentityMustBeExactAndHistoricalMetadataDoesNotSubstitute() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: AnnotationContextError.currentBookUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 3)
        }
        #expect(throws: AnnotationContextError.currentBookAmbiguous) {
            _ = try fixture.books.annotationContext(localPK: 4)
        }
        #expect(throws: AnnotationContextError.assetIdentityUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 5)
        }
        #expect(throws: AnnotationContextError.contentPathUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 6)
        }
    }

    @Test
    func invalidWindowAndMissingChapterIdentityFailBeforeContentRead() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(throws: AnnotationContextError.invalidWindow) {
            _ = try fixture.books.annotationContext(localPK: 7, charsBefore: -1, charsAfter: 10)
        }
        #expect(throws: AnnotationContextError.chapterUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 7)
        }
        #expect(throws: AnnotationContextError.annotationUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 8)
        }
        #expect(throws: AnnotationContextError.annotationUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 9)
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = temporaryDirectory()
        let epub = try makeEPUB(in: root)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'asset-current','\(sql(epub.path))'),
          (2,'asset-dup','\(sql(epub.path))'),
          (3,'asset-dup','\(sql(epub.path))'),
          (4,'asset-no-path',NULL),
          (5,'asset-no-hint','/tmp/should-not-be-opened.epub');
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONREPRESENTATIVETEXT TEXT,
          ZANNOTATIONLOCATION TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'asset-current',0,1,'quick brown','wrong','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (2,'asset-current',0,1,'','brown fox','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (3,'asset-missing',0,1,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (4,'asset-dup',0,1,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (5,NULL,0,1,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (6,'asset-no-path',0,1,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (7,'asset-no-hint',0,1,'quick brown','','epubcfi(/6/2!/4/2,:0,:0)'),
          (8,'asset-current',1,1,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)'),
          (9,'asset-current',0,3,'quick brown','','epubcfi(/6/2[chapter]!/4/2,:0,:0)');
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{\"asset-missing\":{\"title\":\"Synthetic\",\"author\":\"Synthetic\"}}}".utf8).write(to: config)
        return Fixture(
            root: root,
            books: try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        )
    }

    private func makeEPUB(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("context.epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body><p>zero prefix The quick</p><p>brown fox suffix end</p></body></html>".utf8).write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
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

    private struct Fixture {
        let root: URL
        let books: AppleBooks
    }
}

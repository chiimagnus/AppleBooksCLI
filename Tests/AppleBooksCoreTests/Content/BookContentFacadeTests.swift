import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("BookContentFacadeTests")
struct BookContentFacadeTests {
    @Test
    func facadeRequiresPathCapabilityAndOpensDirectoryEPUB() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let epub = try makeEPUB(in: root)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1,'\(epub.path.replacingOccurrences(of: "'", with: "''"))'),(2,NULL),(3,'/tmp/missing.epub'),(4,'/tmp/not-a-book.pdf');
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY);")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let books = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)

        #expect(try books.bookContent(forBookLocalPK: 1).listChapters().map(\.id) == ["chapter"])
        #expect(throws: ContentError.bookPathUnavailable) { _ = try books.bookContent(forBookLocalPK: 2) }
        #expect(throws: ContentError.unavailable(.missing)) { _ = try books.bookContent(forBookLocalPK: 3) }
        #expect(throws: ContentError.unsupportedFormat) { _ = try books.bookContent(forBookLocalPK: 4) }
    }

    @Test
    func missingPathColumnFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY); INSERT INTO ZBKLIBRARYASSET VALUES(1);")
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: "CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY);")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let books = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZPATH"])) {
            _ = try books.bookContent(forBookLocalPK: 1)
        }
    }

    private func makeEPUB(in parent: URL) throws -> URL {
        let root = parent.appendingPathComponent("Synthetic.EPUB")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
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
        let result = sqlite3_open(url.path, &handle)
        guard result == SQLITE_OK, let handle else { throw SQLiteError.current(operation: .open, code: result, handle: handle) }
        defer { sqlite3_close(handle) }
        let execution = sqlite3_exec(handle, sql, nil, nil, nil)
        guard execution == SQLITE_OK else { throw SQLiteError.current(operation: .step, code: execution, handle: handle) }
        return url
    }
}

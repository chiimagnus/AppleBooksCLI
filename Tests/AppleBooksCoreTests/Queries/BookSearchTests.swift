import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("BookSearchTests")
struct BookSearchTests {
    @Test
    func combinedSearchMatchesTitleAuthorAndGenreWithStableLiteralSemantics() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZAUTHOR TEXT,
            ZGENRE TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1,'asset-1','Alpha','Writer','Science'),
            (2,'asset-2','Beta','Alpha Author','History'),
            (3,'asset-3','Gamma','Other','Alpha Genre'),
            (4,'asset-4','100%_ Literal','Other','Other'),
            (5,'asset-5','100xx Literal','Other','Other');
        """)
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let core = try AppleBooks(libraryDB: library, annotationsDB: annotations, historicalConfig: config)

        #expect(try core.books(matching: "Alpha").map(\.localPK) == [1, 2, 3])
        #expect(try core.books(matching: "%_").map(\.localPK) == [4])
    }

    @Test
    func combinedSearchUsesOnlyColumnsPresentInCurrentSchema() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZAUTHOR TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (2,'Needle Author'),(1,'Other');
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: library.path))

        #expect(try queries.search("needle").map(\.localPK) == [2])
    }

    @Test
    func emptyQueryAndMissingSearchColumnsFailBeforeInvalidSearchSQL() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let noTable = root.appendingPathComponent("empty.sqlite")
        try createDatabase(noTable, sql: "CREATE TABLE placeholder(value INTEGER);")
        let emptyQueries = BookQueries(connection: try SQLiteConnection.readOnly(path: noTable.path))
        #expect(throws: BookSearchError.emptyQuery) {
            _ = try emptyQueries.search("")
        }

        let noSearchColumns = root.appendingPathComponent("no-search.sqlite")
        try createDatabase(noSearchColumns, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY); INSERT INTO ZBKLIBRARYASSET VALUES (1);")
        let noSearchQueries = BookQueries(connection: try SQLiteConnection.readOnly(path: noSearchColumns.path))
        #expect(throws: BookSearchError.noSearchableColumns) {
            _ = try noSearchQueries.search("anything")
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createDatabase(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close_v2(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }
}

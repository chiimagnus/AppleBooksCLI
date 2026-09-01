import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PDFSourceResolverTests")
struct PDFSourceResolverTests {
    @Test
    func pdfBooksRequireContentTypeAndFilterExactThree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZCONTENTTYPE INTEGER,
          ZTITLE TEXT,
          ZPATH TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1, 3, 'PDF', '/tmp/current.pdf'),
          (2, 1, 'EPUB', '/tmp/current.epub'),
          (3, NULL, 'Unknown', '/tmp/unknown.pdf');
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))

        let books = try queries.pdfBooks()
        #expect(books.map(\.localPK) == [1])
        #expect(books[0].contentType == 3)
        #expect(books[0].path == "/tmp/current.pdf")

        let missingColumn = root.appendingPathComponent("missing-content-type.sqlite")
        try createDatabase(missingColumn, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZPATH TEXT);")
        let incomplete = BookQueries(connection: try SQLiteConnection.readOnly(path: missingColumn.path))
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZCONTENTTYPE"])) {
            _ = try incomplete.pdfBooks()
        }
    }

    @Test
    func resolvesExactDatabasePathsAndOnlyDirectFallbackPDFs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackRoot = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)

        let exact = root.appendingPathComponent("exact.pdf")
        try Data("exact".utf8).write(to: exact)
        let duplicate = fallbackRoot.appendingPathComponent("duplicate.pdf")
        try Data("duplicate".utf8).write(to: duplicate)
        let fallback = fallbackRoot.appendingPathComponent("fallback.pdf")
        try Data("fallback".utf8).write(to: fallback)
        try Data("not pdf".utf8).write(to: fallbackRoot.appendingPathComponent("ignored.txt"))
        try FileManager.default.createDirectory(at: fallbackRoot.appendingPathComponent("directory.pdf"), withIntermediateDirectories: false)

        let nested = fallbackRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("nested.pdf"))

        let symlink = fallbackRoot.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: exact)

        let missing = root.appendingPathComponent("missing.pdf")
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZCONTENTTYPE INTEGER,
          ZTITLE TEXT,
          ZPATH TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1, 3, 'Exact title', '\(sql(exact.path))'),
          (2, 3, 'Missing title', '\(sql(missing.path))'),
          (3, 3, 'Duplicate A', '\(sql(duplicate.path))'),
          (4, 3, 'Duplicate B', '\(sql(duplicate.path))'),
          (5, 1, 'Not a PDF row', '\(sql(fallback.path))');
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        let sources = PDFSourceResolver(fallbackRoot: fallbackRoot).resolve(pdfBooks: try queries.pdfBooks())

        #expect(sources.map(\.fileURL) == [exact, duplicate, fallback].map { $0.standardizedFileURL.resolvingSymlinksInPath() }.sorted { $0.path < $1.path })

        let exactSource = try #require(sources.first { $0.fileURL == exact.standardizedFileURL.resolvingSymlinksInPath() })
        #expect(exactSource.book?.localPK == 1)
        #expect(exactSource.displayTitle == "Exact title")
        #expect(exactSource.provenance == .library)

        let duplicateSource = try #require(sources.first { $0.fileURL == duplicate.standardizedFileURL.resolvingSymlinksInPath() })
        #expect(duplicateSource.book == nil)
        #expect(duplicateSource.displayTitle == "duplicate")
        #expect(duplicateSource.provenance == .library)

        let fallbackSource = try #require(sources.first { $0.fileURL == fallback.standardizedFileURL.resolvingSymlinksInPath() })
        #expect(fallbackSource.book == nil)
        #expect(fallbackSource.displayTitle == "fallback")
        #expect(fallbackSource.provenance == .fallback)
        let explicit = root.appendingPathComponent("explicit.pdf")
        try Data("explicit".utf8).write(to: explicit)
        let explicitSource = try #require(PDFSourceResolver(fallbackRoot: fallbackRoot).resolve(fileURL: explicit, pdfBooks: try queries.pdfBooks()))
        #expect(explicitSource.book == nil)
        #expect(explicitSource.provenance == .explicit)
        #expect(sources.contains { $0.fileURL.lastPathComponent == "nested.pdf" } == false)
        #expect(sources.contains { $0.fileURL.lastPathComponent == "linked.pdf" } == false)
        #expect(sources.contains { $0.fileURL.lastPathComponent == "directory.pdf" } == false)
    }

    @Test
    func rejectsUnsafeOrUnreadableDatabasePaths() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackRoot = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)

        let target = root.appendingPathComponent("target.pdf")
        try Data("target".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let unreadable = root.appendingPathComponent("unreadable.pdf")
        try Data("unreadable".utf8).write(to: unreadable)
        #expect(chmod(unreadable.path, 0o000) == 0)
        let directory = root.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let wrongExtension = root.appendingPathComponent("wrong.txt")
        try Data("wrong".utf8).write(to: wrongExtension)

        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZCONTENTTYPE INTEGER, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1, 3, '\(sql(symlink.path))'),
          (2, 3, '\(sql(unreadable.path))'),
          (3, 3, '\(sql(directory.path))'),
          (4, 3, '\(sql(wrongExtension.path))'),
          (5, 3, 'relative.pdf');
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))

        #expect(PDFSourceResolver(fallbackRoot: fallbackRoot).resolve(pdfBooks: try queries.pdfBooks()).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

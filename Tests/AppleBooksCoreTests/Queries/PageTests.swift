import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PageTests")
struct PageTests {
    @Test
    func bookPageUsesContentScopeDefaultTwentyAndKeepsUnlimitedList() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.core.bookPage()
        #expect(first.total == 22)
        #expect(first.limit == 20)
        #expect(first.offset == 0)
        #expect(first.items.count == 20)
        #expect(first.items.first?.localPK == 1)
        #expect(first.items.last?.localPK == 20)

        let tail = try fixture.core.bookPage(limit: 5, offset: 20)
        #expect(tail.total == 22)
        #expect(tail.items.map(\.localPK) == [21, 22])
        #expect(try fixture.core.listBooks().count == 23)
    }

    @Test
    func annotationPagesShareExactScopeWithCountAndDefaultFifty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let raw = try fixture.core.annotationPage()
        #expect(raw.total == 3)
        #expect(raw.limit == 50)
        #expect(raw.items.map { $0.annotation.localPK } == [3, 2, 1])

        let user = try fixture.core.annotationPage(scope: .user)
        #expect(user.total == 1)
        #expect(user.items.map { $0.annotation.localPK } == [1])

        let rawGreen = try fixture.core.annotationPage(colorName: "green")
        #expect(rawGreen.total == 2)
        #expect(rawGreen.items.map { $0.annotation.localPK } == [2, 1])

        let userGreen = try fixture.core.annotationPage(colorName: "GREEN", scope: .user)
        #expect(userGreen.total == 1)
        #expect(userGreen.items.map { $0.annotation.localPK } == [1])
    }

    @Test
    func invalidPageInputRejectsBeforeDatabaseInspection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("empty.sqlite")
        try createDatabase(database, sql: "CREATE TABLE placeholder(value INTEGER);")
        let books = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))

        #expect(throws: PageInputError.limitOutOfRange) {
            _ = try books.page(limit: 0)
        }
        #expect(throws: PageInputError.limitOutOfRange) {
            _ = try books.page(limit: 101)
        }
        #expect(throws: PageInputError.negativeOffset) {
            _ = try books.page(offset: -1)
        }
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let library = root.appendingPathComponent("library.sqlite")
            let bookRows = (1...22).map { index in
                "(\(index),'asset-\(index)','\(String(format: "Book %02d", index))',1)"
            }.joined(separator: ",")
            try PageTests().createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(
                Z_PK INTEGER PRIMARY KEY,
                ZASSETID TEXT,
                ZTITLE TEXT,
                ZCONTENTTYPE INTEGER
            );
            INSERT INTO ZBKLIBRARYASSET VALUES \(bookRows);
            INSERT INTO ZBKLIBRARYASSET VALUES (99,'asset-null','Not Paged',NULL);
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try PageTests().createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER,
                ZANNOTATIONSTYLE INTEGER,
                ZANNOTATIONMODIFICATIONDATE REAL
            );
            INSERT INTO ZAEANNOTATION VALUES
                (1,0,1,1,100),
                (2,0,3,1,200),
                (3,0,NULL,2,300),
                (4,1,1,1,400),
                (5,NULL,1,1,500);
            """)

            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
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

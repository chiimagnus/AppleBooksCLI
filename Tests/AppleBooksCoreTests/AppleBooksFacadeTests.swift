import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AppleBooksFacadeTests")
struct AppleBooksFacadeTests {
    @Test
    func exposesOnlyThePlannedReadSemanticsAndResolvesCurrentLocationFromBookPk() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let books = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.config
        )

        #expect(try books.listCollections().map(\.localPK) == [1])
        #expect(try books.collection(localPK: 1)?.title == "Shelf")
        #expect(try books.collections(matchingTitle: "helf").map(\.localPK) == [1])
        #expect(try books.listBooks().map(\.localPK) == [1, 2, 3])
        #expect(try books.book(localPK: 1)?.assetID == "asset-a")
        #expect(try books.books(matchingTitle: "alpha").map(\.localPK) == [1])
        #expect(try books.books(matchingGenre: "Fic").map(\.localPK) == [1, 2])

        #expect(try books.listAnnotations().map { $0.annotation.localPK } == [10])
        #expect(try books.annotation(localPK: 11) == nil)
        #expect(try books.annotations(colorName: "yellow").map { $0.annotation.localPK } == [10])
        #expect(try books.annotations(matchingHighlightedText: "quote").map { $0.annotation.localPK } == [10])
        #expect(try books.annotations(matchingNote: "note").map { $0.annotation.localPK } == [10])
        #expect(try books.annotations(matchingText: "representative").map { $0.annotation.localPK } == [10])
        let lower = try #require(CoreDataTime.date(from: 50))
        let upper = try #require(CoreDataTime.date(from: 150))
        #expect(try books.annotations(createdAtOrAfter: lower, beforeExclusive: upper).map { $0.annotation.localPK } == [10])

        #expect(try books.booksInProgress().map(\.localPK) == [1])
        #expect(try books.finishedBooks().map(\.localPK) == [2])
        #expect(try books.unstartedBooks().map(\.localPK) == [3])
        #expect(try books.recentlyReadBooks().map(\.localPK) == [2, 1])
        #expect(try books.currentReadingLocation(forBookLocalPK: 1)?.localPK == 11)
        #expect(try books.currentReadingLocation(forBookLocalPK: 999) == nil)
    }

    @Test
    func currentLocationFailsClosedWhenBookAssetIdColumnIsMissing() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);
        INSERT INTO ZBKLIBRARYASSET VALUES (1);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT
        );
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let books = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .books,
            columns: ["ZASSETID"]
        )) {
            _ = try books.currentReadingLocation(forBookLocalPK: 1)
        }
    }

    private func fixture() throws -> Fixture {
        let root = temporaryDirectory()
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZGENRE TEXT,
          ZISFINISHED INTEGER,
          ZREADINGPROGRESS REAL,
          ZDATEFINISHED REAL,
          ZLASTOPENDATE REAL
        );
        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          ZTITLE TEXT,
          ZDELETEDFLAG INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'asset-a','Alpha','Fiction',0,0.5,NULL,100),
          (2,'asset-b','Beta','Fiction',1,0,200,200),
          (3,NULL,'Gamma','Other',0,NULL,NULL,NULL);
        INSERT INTO ZBKCOLLECTION VALUES (1,'Shelf',0),(2,'Deleted',1);
        """)
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONUUID TEXT,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONSTYLE INTEGER,
          ZANNOTATIONCREATIONDATE REAL,
          ZANNOTATIONMODIFICATIONDATE REAL,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONREPRESENTATIVETEXT TEXT,
          ZANNOTATIONNOTE TEXT,
          ZANNOTATIONLOCATION TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (10,'uuid-user','asset-a',0,1,3,100,150,'quote','representative','note',NULL),
          (11,'uuid-position','asset-a',0,3,0,110,160,'','','','epubcfi(/6/8[current]!/4/2,:1,:1)'),
          (12,'uuid-deleted','asset-a',1,1,3,120,170,'deleted','','',NULL);
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return Fixture(root: root, library: library, annotations: annotations, config: config)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func database(at url: URL, sql: String) throws -> URL {
        var database: OpaquePointer?
        let open = sqlite3_open(url.path, &database)
        guard open == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: open, handle: database)
        }
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
        return url
    }

    private struct Fixture {
        let root: URL
        let library: URL
        let annotations: URL
        let config: URL
    }
}

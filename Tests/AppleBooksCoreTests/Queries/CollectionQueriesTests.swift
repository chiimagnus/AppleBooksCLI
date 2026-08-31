import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CollectionQueriesTests")
struct CollectionQueriesTests {
    @Test
    func listGetAndSearchExcludeDeletedAndUnknownDeletedState() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTIONID TEXT,
            ZTITLE TEXT,
            ZDETAILS TEXT,
            ZDELETEDFLAG INTEGER,
            ZHIDDEN INTEGER
        );
        INSERT INTO ZBKCOLLECTION VALUES
            (1, 'one', 'Beta', NULL, 0, 0),
            (2, 'two', 'alpha', 'detail', 0, 1),
            (3, 'three', 'Alpha', NULL, 1, 0),
            (4, 'four', 'Alpha', NULL, NULL, 0),
            (5, 'five', NULL, NULL, 0, NULL),
            (6, 'six', 'alpha', NULL, 0, 0);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.list().map(\.localPK) == [2, 6, 1, 5])
        #expect(try queries.searchTitle("ALPHA").map(\.localPK) == [2, 6])
        #expect(try queries.getByLocalPK(1)?.title == "Beta")
        #expect(try queries.getByLocalPK(3) == nil)
        #expect(try queries.getByLocalPK(4) == nil)
    }

    @Test
    func listFallsBackToLocalPkWhenOptionalTitleIsAbsent() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY, ZDELETEDFLAG INTEGER);
        INSERT INTO ZBKCOLLECTION VALUES (3, 0), (2, 1), (1, 0), (4, NULL);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        #expect(try queries.list().map(\.localPK) == [1, 3])
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .collections, columns: ["ZTITLE"])) {
            _ = try queries.searchTitle("anything")
        }
    }

    @Test
    func collectionBooksUseMemberOrderSkipStaleAndDeduplicateMembership() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY, ZDELETEDFLAG INTEGER, ZTITLE TEXT);
        CREATE TABLE ZBKCOLLECTIONMEMBER(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTION INTEGER,
            ZASSETID TEXT,
            ZSORTKEY REAL
        );
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT);
        INSERT INTO ZBKCOLLECTION VALUES (1, 0, 'Synthetic');
        INSERT INTO ZBKLIBRARYASSET VALUES
            (10, 'asset-a', 'A'),
            (11, 'asset-b', 'B'),
            (12, 'asset-b', 'B duplicate source row');
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES
            (100, 1, 'asset-a', 20),
            (101, 1, 'asset-b', 10),
            (102, 1, 'missing-asset', 15),
            (103, 1, 'asset-b', 30),
            (104, 1, NULL, 5),
            (105, 2, 'asset-a', 1);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        let maybeCollection = try queries.getByLocalPK(1)
        let collection = try #require(maybeCollection)
        #expect(try queries.books(in: collection).map(\.localPK) == [11, 12, 10])
    }

    @Test
    func memberOrderFallsBackToMemberPkWhenSortKeyColumnIsAbsent() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY, ZDELETEDFLAG INTEGER);
        CREATE TABLE ZBKCOLLECTIONMEMBER(Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER, ZASSETID TEXT);
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT);
        INSERT INTO ZBKCOLLECTION VALUES (1, 0);
        INSERT INTO ZBKLIBRARYASSET VALUES (10, 'asset-a'), (11, 'asset-b');
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES (2, 1, 'asset-b'), (1, 1, 'asset-a');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        let maybeCollection = try queries.getByLocalPK(1)
        let collection = try #require(maybeCollection)
        #expect(try queries.books(in: collection).map(\.localPK) == [10, 11])
    }

    @Test
    func emptyCollectionReturnsNoBooksAndMissingRelationColumnsFailClosed() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY, ZDELETEDFLAG INTEGER);
        CREATE TABLE ZBKCOLLECTIONMEMBER(Z_PK INTEGER PRIMARY KEY, ZCOLLECTION INTEGER);
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT);
        INSERT INTO ZBKCOLLECTION VALUES (1, 0);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        let maybeCollection = try queries.getByLocalPK(1)
        let collection = try #require(maybeCollection)
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .collectionMembers, columns: ["ZASSETID"])) {
            _ = try queries.books(in: collection)
        }
    }

    private func queries(for url: URL) throws -> CollectionQueries {
        CollectionQueries(connection: try SQLiteConnection.readOnly(path: url.path))
    }

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("collections.sqlite")
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
}

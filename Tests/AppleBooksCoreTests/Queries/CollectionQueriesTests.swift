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
            ZHIDDEN INTEGER,
            ZPLACEHOLDER INTEGER,
            ZSORTKEY INTEGER,
            ZSORTMODE INTEGER,
            ZVIEWMODE INTEGER,
            ZLASTMODIFICATION REAL,
            ZLOCALMODDATE REAL
        );
        INSERT INTO ZBKCOLLECTION VALUES
            (1, 'one', 'Beta', NULL, 0, 0, 0, 100, 6, 2, 10.5, 11.5),
            (2, 'two', 'alpha', 'detail', 0, 1, 1, 200, 7, 3, 20.5, 21.5),
            (3, 'three', 'Alpha', NULL, 1, 0, 0, 300, 6, 2, 30.5, 31.5),
            (4, 'four', 'Alpha', NULL, NULL, 0, 0, 400, 6, 2, 40.5, 41.5),
            (5, 'five', NULL, NULL, 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
            (6, 'six', 'alpha', NULL, 0, 0, 0, 600, 6, 2, 60.5, 61.5);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.list().map(\.localPK) == [2, 6, 1, 5])
        #expect(try queries.searchTitle("ALPHA").map(\.localPK) == [2, 6])
        let first = try #require(try queries.getByLocalPK(1))
        #expect(first.title == "Beta")
        #expect(first.isPlaceholder == false)
        #expect(first.sortKey == 100)
        #expect(first.sortMode == 6)
        #expect(first.viewMode == 2)
        #expect(first.lastModificationDate == CoreDataTime.date(from: 10.5))
        #expect(first.localModificationDate == CoreDataTime.date(from: 11.5))
        let optional = try #require(try queries.getByLocalPK(5))
        #expect(optional.sortKey == nil)
        #expect(optional.lastModificationDate == nil)
        #expect(try queries.getByLocalPK(3) == nil)
        #expect(try queries.getByLocalPK(4) == nil)
    }

    @Test
    func semanticCollectionBoundsMultiMiBTextAndOversizeIdentityWhileRawCollectionStaysFullFidelity() throws {
        let title = String(repeating: "t", count: 1_048_576)
        let details = String(repeating: "d", count: 1_048_576)
        let exactID = String(repeating: "i", count: 2_048)
        let oversizedID = String(repeating: "j", count: 2_049)
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTIONID TEXT,
            ZTITLE TEXT,
            ZDETAILS TEXT,
            ZDELETEDFLAG INTEGER
        );
        INSERT INTO ZBKCOLLECTION VALUES
            (1, '\(exactID)', '\(title)', '\(details)', 0),
            (2, '\(oversizedID)', 'small', 'small', 0);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let exact = try #require(try queries.semanticGetByLocalPK(1))
        #expect(exact.collectionID == exactID)
        #expect(exact.title?.utf8.count == SQLiteSemanticTextBudget.metadata)
        #expect(exact.details?.utf8.count == SQLiteSemanticTextBudget.detail)
        #expect(Set(exact.byteTruncatedFields) == ["title", "details"])

        let oversized = try #require(try queries.semanticGetByLocalPK(2))
        #expect(oversized.collectionID == nil)

        let rawExact = try #require(try queries.getByLocalPK(1))
        #expect(rawExact.title?.utf8.count == title.utf8.count)
        #expect(rawExact.details?.utf8.count == details.utf8.count)
        let rawOversized = try #require(try queries.getByLocalPK(2))
        #expect(rawOversized.collectionID == oversizedID)
    }

    @Test
    func uniqueCollectionResolutionStopsAfterTwoRowsWithoutDecodingRichFields() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTIONID TEXT,
            ZTITLE TEXT,
            ZDELETEDFLAG INTEGER
        );
        WITH RECURSIVE seq(x) AS (
            VALUES(1)
            UNION ALL
            SELECT x + 1 FROM seq WHERE x < 10001
        )
        INSERT INTO ZBKCOLLECTION
        SELECT x, 'duplicate-collection', CAST(X'FF' AS TEXT), 0 FROM seq;
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(throws: StableIdentityError.ambiguousCollectionID) {
            _ = try queries.getUniqueByCollectionID("duplicate-collection")
        }
        #expect(throws: SQLiteRowError.invalidUTF8(column: "ZTITLE")) {
            _ = try queries.list()
        }
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

    @Test
    func semanticCollectionPagesUseSQLiteNoCaseNullOrder() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTIONID TEXT,
            ZTITLE TEXT,
            ZDELETEDFLAG INTEGER
        );
        INSERT INTO ZBKCOLLECTION VALUES
            (1, 'one', 'beta', 0),
            (2, 'two', 'Alpha', 0),
            (3, 'three', 'alpha', 0),
            (4, 'four', NULL, 0),
            (5, 'deleted', 'aardvark', 1);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let first = try queries.semanticListPage(limit: 2)
        #expect(first.items.map(\.localPK) == [2, 3])
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let second = try queries.semanticListPage(limit: 2, cursor: cursor)
        #expect(second.items.map(\.localPK) == [1, 4])
        #expect(second.hasMore == false)
        #expect(second.nextCursor == nil)

        let searchFirst = try queries.semanticSearchTitlePage("ALP", limit: 1)
        #expect(searchFirst.items.map(\.localPK) == [2])
        let searchCursor = try #require(searchFirst.nextCursor)
        let searchSecond = try queries.semanticSearchTitlePage("ALP", limit: 1, cursor: searchCursor)
        #expect(searchSecond.items.map(\.localPK) == [3])
        #expect(searchSecond.hasMore == false)
    }

    @Test
    func semanticCollectionCapabilitiesUseRawIdentityWithoutPublishingInvalidTokens() throws {
        let oversized = String(repeating: "x", count: PublicStableIdentityPolicy.maximumUTF8Bytes + 1)
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTIONID TEXT,
            ZTITLE TEXT,
            ZDELETEDFLAG INTEGER
        );
        INSERT INTO ZBKCOLLECTION VALUES
            (1, '550E8400-E29B-41D4-A716-446655440000', 'A', 0),
            (2, 'Want_To_Read_Collection_ID', 'B', 0),
            (3, 'Books_Collection_ID', 'C', 0),
            (4, NULL, 'D', 0),
            (5, '\(oversized)', 'E', 0);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let page = try queries.semanticListPage(limit: 10)
        let byPK = Dictionary(uniqueKeysWithValues: page.items.map { ($0.localPK, $0) })
        #expect(byPK[1]?.canEditCollection == true)
        #expect(byPK[1]?.canEditMembership == true)
        #expect(byPK[2]?.canEditCollection == false)
        #expect(byPK[2]?.canEditMembership == true)
        for pk in [Int64(3), 4, 5] {
            #expect(byPK[pk]?.canEditCollection == false)
            #expect(byPK[pk]?.canEditMembership == false)
        }
        #expect(byPK[5]?.collectionID == nil)

        let detail = try #require(try queries.semanticGetByLocalPK(2))
        #expect(detail.canEditCollection == false)
        #expect(detail.canEditMembership == true)
    }

    @Test
    func membershipCursorPagesMatchFullCanonicalSequenceAcrossDuplicatesAndStaleRows() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKCOLLECTION(Z_PK INTEGER PRIMARY KEY, ZDELETEDFLAG INTEGER, ZTITLE TEXT);
        CREATE TABLE ZBKCOLLECTIONMEMBER(
            Z_PK INTEGER PRIMARY KEY,
            ZCOLLECTION INTEGER,
            ZASSETID TEXT,
            ZSORTKEY REAL
        );
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT
        );
        INSERT INTO ZBKCOLLECTION VALUES (1, 0, 'Synthetic');
        WITH RECURSIVE seq(x) AS (
            VALUES(1)
            UNION ALL
            SELECT x + 1 FROM seq WHERE x < 125
        )
        INSERT INTO ZBKLIBRARYASSET
        SELECT x, printf('asset-%03d', x), printf('Book %03d', x) FROM seq;
        INSERT INTO ZBKLIBRARYASSET VALUES (1000, 'asset-001', 'Duplicate source book row');
        WITH RECURSIVE seq(x) AS (
            VALUES(1)
            UNION ALL
            SELECT x + 1 FROM seq WHERE x < 125
        )
        INSERT INTO ZBKCOLLECTIONMEMBER
        SELECT x, 1, printf('asset-%03d', x), CASE WHEN x % 10 = 0 THEN NULL ELSE x % 7 END FROM seq;
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES
            (1001, 1, 'asset-001', 999),
            (1002, 1, 'asset-050', 999),
            (1003, 1, 'missing-asset', -1),
            (1004, 1, NULL, -2);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        let semanticCollection = try #require(try queries.semanticGetByLocalPK(1))
        let rawCollection = try #require(try queries.getByLocalPK(1))
        var expectedMembers: [(memberPK: Int, sortKey: Int?)] = (1...125).map { value in
            (memberPK: value, sortKey: value % 10 == 0 ? nil : value % 7)
        }
        expectedMembers.sort { lhs, rhs in
            if lhs.sortKey == nil { return rhs.sortKey != nil || lhs.memberPK < rhs.memberPK }
            if rhs.sortKey == nil { return false }
            let left = lhs.sortKey!
            let right = rhs.sortKey!
            return left == right ? lhs.memberPK < rhs.memberPK : left < right
        }
        let expectedLocalPKs: [Int64] = expectedMembers.flatMap { row in
            row.memberPK == 1 ? [1, 1_000] : [Int64(row.memberPK)]
        }
        let fullLocalPKs = try queries.books(in: rawCollection).map(\.localPK)
        #expect(fullLocalPKs == expectedLocalPKs)
        #expect(Set(fullLocalPKs).count == 126)

        var paged: [BookSummary] = []
        var cursor: String?
        repeat {
            let page = try queries.semanticBooksPage(in: semanticCollection, limit: 20, cursor: cursor)
            paged.append(contentsOf: page.items)
            cursor = page.nextCursor
            if page.hasMore == false { #expect(cursor == nil) }
        } while cursor != nil

        #expect(paged.map(\.localPK) == fullLocalPKs)
        #expect(Set(paged.map(\.localPK)).count == paged.count)
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

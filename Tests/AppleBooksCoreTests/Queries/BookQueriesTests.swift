import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("BookQueriesTests")
struct BookQueriesTests {
    @Test
    func listAndSearchUseStableOrderingAndLiteralContains() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZGENRE TEXT,
            ZREADINGPROGRESS REAL,
            ZISFINISHED INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, 'asset-b', 'Beta', 'Science', 0.1, 0),
            (2, 'asset-a', 'alpha', 'Sci%Fi', 0.2, 0),
            (3, 'asset-c', 'Alpha', 'Under_score', 0.3, 1),
            (4, NULL, NULL, 'Back\\Slash', NULL, NULL),
            (5, 'asset-quote', 'O''Reilly 100%_\\ Guide', 'Quote', 1.25, 0),
            (6, 'asset-a', 'Gamma', 'Other', 0.4, 0);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.list().map(\.localPK) == [2, 3, 1, 6, 5, 4])
        #expect(try queries.list(limit: 2, offset: 1).map(\.localPK) == [3, 1])
        #expect(try queries.searchTitle("ALPHA").map(\.localPK) == [2, 3])
        #expect(try queries.searchTitle("%").map(\.localPK) == [5])
        #expect(try queries.searchTitle("_").map(\.localPK) == [5])
        #expect(try queries.searchTitle("\\").map(\.localPK) == [5])
        #expect(try queries.searchTitle("O'Reilly").map(\.localPK) == [5])
        #expect(try queries.searchGenre("Sci%").map(\.localPK) == [2])
        #expect(try queries.getByAssetID("asset-a").map(\.localPK) == [2, 6])
        #expect(try queries.getByLocalPK(999) == nil)
        #expect(try queries.getByLocalPK(5)?.readingProgressRaw == 1.25)
        #expect(try queries.getByLocalPK(5)?.readingProgressPercent == 125)
    }

    @Test
    func rawAssetIdentityPreservesEmbeddedNULWhileSemanticSummaryRejectsIt() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, CAST(X'61626300646566' AS TEXT), 'NUL Identity');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let exact = try queries.getUniqueByAssetID("abc\0def")
        #expect(exact?.localPK == 1)
        #expect(exact?.assetID == "abc\0def")
        #expect(try queries.getUniqueByAssetID("abc") == nil)

        let summary = try #require(try queries.summaryPage().items.first)
        #expect(summary.assetID == nil)
    }

    @Test
    func semanticSummaryBoundsMultiMiBDisplayAndOversizeIdentityWhileRawBookStaysFullFidelity() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZAUTHOR TEXT,
            ZCONTENTTYPE INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES(
            1,
            replace(hex(zeroblob(2049)), '00', 'i'),
            replace(hex(zeroblob(1048576)), '00', 't'),
            replace(hex(zeroblob(1048576)), '00', 'a'),
            1
        );
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let summary = try #require(try queries.summaryPage().items.first)
        #expect(summary.assetID == nil)
        #expect(summary.title?.utf8.count == SQLiteSemanticTextBudget.metadata)
        #expect(summary.author?.utf8.count == SQLiteSemanticTextBudget.metadata)
        #expect(summary.byteTruncatedFields == ["title", "author"])

        let raw = try #require(try queries.getByLocalPK(1))
        #expect(raw.assetID?.utf8.count == 2_049)
        #expect(raw.title?.utf8.count == 1_048_576)
        #expect(raw.author?.utf8.count == 1_048_576)
    }

    @Test
    func resourceTargetRejectsOversizeNULAndNonTextPathsBeforeFilesystemUseWhileRawPathRemainsVisible() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZPATH,
            ZCONTENTTYPE INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, 'ok-4096', 'A', replace(hex(zeroblob(4096)), '00', 'p'), 1),
            (2, 'too-long', 'B', replace(hex(zeroblob(4097)), '00', 'q'), 1),
            (3, 'nul-path', 'C', CAST(X'2F746D7000666F6F' AS TEXT), 1),
            (4, 'numeric-path', 'D', 42, 1),
            (5, 'huge-path', 'E', replace(hex(zeroblob(1048576)), '00', 'h'), 1);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.resourceTarget(localPK: 1)?.path?.utf8.count == 4_096)
        #expect(try queries.resourceTarget(localPK: 2)?.path == nil)
        #expect(try queries.resourceTarget(localPK: 3)?.path == nil)
        #expect(try queries.resourceTarget(localPK: 4)?.path == nil)
        #expect(try queries.resourceTarget(localPK: 5)?.path == nil)

        #expect(try queries.getByLocalPK(2)?.path?.utf8.count == 4_097)
        #expect(try queries.getByLocalPK(3)?.path == "/tmp\0foo")
        #expect(try queries.getByLocalPK(5)?.path?.utf8.count == 1_048_576)
    }

    @Test
    func summaryCursorKeepsFullSQLiteSortKeysWhileProjectionAndTokenStayBounded() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZAUTHOR TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, replace(hex(zeroblob(4096)), '00', 'z'), replace(hex(zeroblob(1048576)), '00', 'a') || 'b', 'One'),
            (2, 'short', replace(hex(zeroblob(1048576)), '00', 'a') || 'c', 'Two');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let first = try queries.summaryPage(limit: 1)
        #expect(first.items.map(\.localPK) == [1])
        #expect(first.items[0].title?.utf8.count == SQLiteSemanticTextBudget.metadata)
        #expect(first.items[0].assetID == nil)
        let cursor = try #require(first.nextCursor)
        #expect(cursor.utf8.count < 1_024)
        #expect(cursor.contains(String(repeating: "a", count: 64)) == false)

        let second = try queries.summaryPage(limit: 1, cursor: cursor)
        #expect(second.items.map(\.localPK) == [2])
    }

    @Test
    func summaryCursorUsesWholeLibraryCanonicalOrderAndMinimalProjection() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZAUTHOR TEXT,
            ZCONTENTTYPE INTEGER,
            ZPATH INTEGER
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, 'asset-z', 'alpha', 'Unknown', 1, 101),
            (2, 'asset-a', 'Alpha', 'Ada\u{E000} Author', 3, 102),
            (3, NULL, 'ALPHA', 'Cara', NULL, 103),
            (4, 'asset-b', NULL, 'Bob', 1, 104),
            (5, 'asset-a', 'alpha', 'Ann', 1, 105);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        let first = try queries.summaryPage(limit: 2)
        #expect(first.total == 5)
        #expect(first.items.map(\.localPK) == [2, 5])
        #expect(first.items[0].author == "Ada Author")
        #expect(first.items[0].isPDF == true)
        #expect(first.hasMore)
        let second = try queries.summaryPage(limit: 2, cursor: first.nextCursor)
        #expect(second.items.map(\.localPK) == [1, 3])
        #expect(second.items[0].author == nil)
        #expect(second.items[1].isPDF == nil)
        let last = try queries.summaryPage(limit: 100, cursor: second.nextCursor)
        #expect(last.items.map(\.localPK) == [4])
        #expect(last.hasMore == false)
        #expect(last.nextCursor == nil)
    }

    @Test
    func summarySearchSupportsExplicitFieldsAndBindsCursorToField() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZAUTHOR TEXT,
            ZGENRE TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, 'a-1', 'Ada Notes', 'Writer', 'Reference'),
            (2, 'a-2', 'Second', 'Ada Author', 'Fiction'),
            (3, 'a-3', 'Third', 'Other', 'Ada Genre');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.searchSummaryPage("Ada", field: .all).items.map(\.localPK) == [1, 2, 3])
        #expect(try queries.searchSummaryPage("Ada", field: .title).items.map(\.localPK) == [1])
        #expect(try queries.searchSummaryPage("Ada", field: .author).items.map(\.localPK) == [2])
        #expect(try queries.searchSummaryPage("Ada", field: .genre).items.map(\.localPK) == [3])

        let first = try queries.searchSummaryPage("a", field: .all, limit: 1)
        #expect(throws: CursorPaginationError.filterMismatch) {
            _ = try queries.searchSummaryPage("a", field: .title, limit: 1, cursor: first.nextCursor)
        }
    }

    @Test
    func uniqueAssetResolutionStopsAfterTwoRowsWhileAllMatchRemainsFullFidelity() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT
        );
        WITH RECURSIVE seq(x) AS (
            VALUES(1)
            UNION ALL
            SELECT x + 1 FROM seq WHERE x < 10001
        )
        INSERT INTO ZBKLIBRARYASSET
        SELECT x, 'duplicate-asset', CAST(X'FF' AS TEXT) FROM seq;
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try queries.getUniqueByAssetID("duplicate-asset")
        }
        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try queries.uniqueResourceTarget(assetID: "duplicate-asset")
        }
        #expect(throws: SQLiteRowError.invalidUTF8(column: "ZTITLE")) {
            _ = try queries.getByAssetID("duplicate-asset")
        }
    }

    @Test
    func explicitMissingSearchFieldFailsWhileAllUsesAvailableColumns() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1, 'Alpha');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)

        #expect(try queries.searchSummaryPage("alp", field: .all).items.map(\.localPK) == [1])
        #expect(throws: BookSearchError.fieldUnavailable(.author)) {
            _ = try queries.searchSummaryPage("alp", field: .author)
        }
        #expect(throws: BookSearchError.fieldUnavailable(.genre)) {
            _ = try queries.searchSummaryPage("alp", field: .genre)
        }
    }

    @Test
    func baseListSurvivesMissingOptionalColumns() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);
        INSERT INTO ZBKLIBRARYASSET VALUES (3), (1), (2);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        let books = try queries.list()
        #expect(books.map(\.localPK) == [1, 2, 3])
        #expect(books.allSatisfy { $0.title == nil && $0.assetID == nil })

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZTITLE"])) {
            _ = try queries.searchTitle("anything")
        }
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZGENRE"])) {
            _ = try queries.searchGenre("anything")
        }
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZASSETID"])) {
            _ = try queries.getByAssetID("asset")
        }
    }

    @Test
    func listCanUseTitleWithoutAssetIdAndAssetLookupStillFailsClosed() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (2, 'Beta'), (1, 'Alpha');
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        #expect(try queries.list().map(\.localPK) == [1, 2])
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZASSETID"])) {
            _ = try queries.getByAssetID("asset")
        }
    }

    @Test
    func paginationValidationRunsBeforeDatabaseAccess() throws {
        let fixture = try database(sql: "CREATE TABLE unrelated(id INTEGER);")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try queries(for: fixture)
        #expect(throws: QueryPaginationError.nonPositiveLimit) {
            _ = try queries.list(limit: 0)
        }
        #expect(throws: QueryPaginationError.negativeOffset) {
            _ = try queries.list(offset: -1)
        }
    }

    private func queries(for url: URL) throws -> BookQueries {
        BookQueries(connection: try SQLiteConnection.readOnly(path: url.path))
    }

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("books.sqlite")
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

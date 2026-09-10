import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ReadingQueriesTests")
struct ReadingQueriesTests {
    @Test
    func readingStatesFormACompleteDisjointPartition() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL,
            ZDATEFINISHED REAL,
            ZLASTOPENDATE REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,1,0,500,100),
          (2,1,0.2,400,110),
          (3,0,0.5,NULL,300),
          (4,NULL,0.2,NULL,200),
          (5,0,NULL,NULL,NULL),
          (6,NULL,0,NULL,50),
          (7,0,-0.1,NULL,60),
          (8,0,1.25,NULL,400),
          (9,2,0,NULL,120);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        try setReal(.infinity, column: "ZREADINGPROGRESS", localPK: 5, database: fixture)
        try setReal(.infinity, column: "ZLASTOPENDATE", localPK: 5, database: fixture)
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: fixture.path))

        let finished = try collectPages(limit: 20) { try queries.semanticFinishedPage(limit: $0, cursor: $1) }
        let inProgress = try collectPages(limit: 20) { try queries.semanticInProgressPage(limit: $0, cursor: $1) }
        let unstarted = try collectPages(limit: 20) { try queries.semanticUnstartedPage(limit: $0, cursor: $1) }
        #expect(finished == [1, 2, 9])
        #expect(inProgress == [8, 3, 4])
        #expect(unstarted == [7, 6, 5])
        #expect(try collectPages(limit: 20) { try queries.semanticRecentlyReadPage(limit: $0, cursor: $1) }.contains(5) == false)
        #expect(try queries.partitionCounts() == ReadingPartitionCounts(finished: 3, inProgress: 3, unstarted: 3))

        let sets = [Set(finished), Set(inProgress), Set(unstarted)]
        #expect(sets[0].isDisjoint(with: sets[1]))
        #expect(sets[0].isDisjoint(with: sets[2]))
        #expect(sets[1].isDisjoint(with: sets[2]))
        #expect(sets.reduce(into: Set<Int64>()) { $0.formUnion($1) }.count == 9)
    }

    @Test
    func optionalSortColumnsFallBackToLocalPK() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,1,0),(3,1,0),(2,0,0.5),(5,0,0.2),(4,0,NULL);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: fixture.path))

        #expect(try collectPages(limit: 20) { try queries.semanticFinishedPage(limit: $0, cursor: $1) } == [3, 1])
        #expect(try collectPages(limit: 20) { try queries.semanticInProgressPage(limit: $0, cursor: $1) } == [5, 2])
        #expect(try collectPages(limit: 20) { try queries.semanticUnstartedPage(limit: $0, cursor: $1) } == [4])
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .books,
            columns: ["ZLASTOPENDATE"]
        )) {
            _ = try queries.semanticRecentlyReadPage()
        }
    }

    @Test
    func semanticCursorPagesPreserveNullBucketsAndStableTies() throws {
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL,
            ZDATEFINISHED REAL,
            ZLASTOPENDATE REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,1,0,500,100),
          (2,1,0,500,110),
          (3,1,0,NULL,120),
          (4,1,0,NULL,130),
          (5,0,0.5,NULL,300),
          (6,0,0.5,NULL,300),
          (7,0,0.5,NULL,NULL),
          (8,0,0,NULL,200),
          (9,0,0,NULL,200),
          (10,0,0,NULL,NULL);
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: fixture.path))

        #expect(try collectPages(limit: 1) { try queries.semanticFinishedPage(limit: $0, cursor: $1) } == [2, 1, 4, 3])
        #expect(try collectPages(limit: 2) { try queries.semanticInProgressPage(limit: $0, cursor: $1) } == [6, 5, 7])
        #expect(try collectPages(limit: 1) { try queries.semanticUnstartedPage(limit: $0, cursor: $1) } == [9, 8, 10])
        #expect(try collectPages(limit: 2) { try queries.semanticRecentlyReadPage(limit: $0, cursor: $1) } == [6, 5, 9, 8, 4, 3, 2, 1])
    }

    private func collectPages(
        limit: Int,
        fetch: (Int, String?) throws -> CursorPage<BookSummary>
    ) throws -> [Int64] {
        var cursor: String?
        var result: [Int64] = []
        repeat {
            let page = try fetch(limit, cursor)
            result += page.items.map(\.localPK)
            cursor = page.nextCursor
            #expect(page.hasMore == (cursor != nil))
        } while cursor != nil
        return result
    }

    private func setReal(_ value: Double, column: String, localPK: Int64, database: URL) throws {
        var handle: OpaquePointer?
        let open = sqlite3_open(database.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, "UPDATE ZBKLIBRARYASSET SET \(column) = ? WHERE Z_PK = ?", -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: prepare, handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, value) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
    }

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("reading.sqlite")
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

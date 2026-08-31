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
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: fixture.path))

        let finished = try queries.finished()
        let inProgress = try queries.inProgress()
        let unstarted = try queries.unstarted()
        #expect(finished.map(\.localPK) == [1, 2, 9])
        #expect(inProgress.map(\.localPK) == [8, 3, 4])
        #expect(unstarted.map(\.localPK) == [7, 6, 5])
        #expect(inProgress.first?.readingProgressRaw == 1.25)

        let sets = [Set(finished.map(\.localPK)), Set(inProgress.map(\.localPK)), Set(unstarted.map(\.localPK))]
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

        #expect(try queries.finished().map(\.localPK) == [3, 1])
        #expect(try queries.inProgress().map(\.localPK) == [5, 2])
        #expect(try queries.unstarted().map(\.localPK) == [4])
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .books,
            columns: ["ZLASTOPENDATE"]
        )) {
            _ = try queries.recentlyRead()
        }
    }

    @Test
    func recentlyReadHasParityDefaultLimitAndStableTies() throws {
        var values: [String] = []
        for pk in 1...12 {
            let timestamp = pk <= 2 ? 500 : Double(100 + pk)
            values.append("(\(pk),0,0,NULL,\(timestamp))")
        }
        let fixture = try database(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL,
            ZDATEFINISHED REAL,
            ZLASTOPENDATE REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES \(values.joined(separator: ","));
        """)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: fixture.path))

        let recent = try queries.recentlyRead()
        #expect(recent.count == 10)
        #expect(recent.prefix(2).map(\.localPK) == [2, 1])
        #expect(try queries.recentlyRead(limit: 2, offset: 1).map(\.localPK) == [1, 12])
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

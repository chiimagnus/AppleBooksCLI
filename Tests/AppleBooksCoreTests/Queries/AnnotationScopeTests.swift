import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationScopeTests")
struct AnnotationScopeTests {
    @Test
    func userAndActiveRawScopesKeepDeletedStateFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.queries.list(scope: .user).map { $0.annotation.localPK } == [1])
        #expect(try fixture.queries.list(scope: .activeRaw).map { $0.annotation.localPK } == [3, 2, 1])
        #expect(try fixture.queries.getByLocalPK(2) == nil)
        #expect(try fixture.queries.getByLocalPK(2, scope: .activeRaw)?.annotation.type == 3)
        #expect(try fixture.queries.getByLocalPK(3, scope: .activeRaw)?.annotation.type == nil)
        #expect(try fixture.queries.getByLocalPK(4, scope: .activeRaw) == nil)
        #expect(try fixture.queries.getByLocalPK(5, scope: .activeRaw) == nil)
    }

    @Test
    func scopeFilteringHappensBeforePagination() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.queries.list(scope: .activeRaw, limit: 2).map { $0.annotation.localPK } == [3, 2])
        #expect(try fixture.queries.list(scope: .activeRaw, limit: 2, offset: 2).map { $0.annotation.localPK } == [1])
        #expect(try fixture.queries.list(limit: 1).map { $0.annotation.localPK } == [1])
    }

    private final class Fixture {
        let root: URL
        let queries: AnnotationQueries

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER
            );
            INSERT INTO ZAEANNOTATION VALUES
                (1,0,1),
                (2,0,3),
                (3,0,NULL),
                (4,1,1),
                (5,NULL,1);
            """)

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)

            queries = AnnotationQueries(
                annotationConnection: try SQLiteConnection.readOnly(path: annotations.path),
                bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: library.path)),
                historicalAssets: try HistoricalAssetMapping(fileURL: config)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
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
}

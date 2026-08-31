import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("RecentlyCreatedAnnotationTests")
struct RecentlyCreatedAnnotationTests {
    @Test
    func returnsUserAnnotationsByCreationThenLocalPKWithDefaultTen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let recent = try fixture.core.recentlyCreatedAnnotations()
        #expect(recent.map { $0.annotation.localPK } == [12, 11, 10, 9, 8, 7, 6, 5, 4, 3])
        #expect(recent.count == 10)
        let orphan = try #require(recent.first { $0.annotation.localPK == 12 })
        #expect(orphan.source == .unmapped)

        let three = try fixture.core.recentlyCreatedAnnotations(limit: 3)
        #expect(three.map { $0.annotation.localPK } == [12, 11, 10])

        let all = try fixture.core.recentlyCreatedAnnotations(limit: 20)
        #expect(all.count == 13)
        #expect(all.last?.annotation.localPK == 13)
    }

    @Test
    func invalidLimitRejectsBeforeSchemaInspection() throws {
        let fixture = try Fixture(annotationSQL: "CREATE TABLE unrelated(value INTEGER);")
        defer { fixture.remove() }

        #expect(throws: QueryPaginationError.nonPositiveLimit) {
            _ = try fixture.core.recentlyCreatedAnnotations(limit: 0)
        }
        #expect(throws: QueryPaginationError.nonPositiveLimit) {
            _ = try fixture.core.recentlyCreatedAnnotations(limit: -1)
        }
    }

    @Test
    func missingCreationColumnFailsClosed() throws {
        let fixture = try Fixture(annotationSQL: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES(1,'asset-a',0,1);
        """)
        defer { fixture.remove() }

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONCREATIONDATE"]
        )) {
            _ = try fixture.core.recentlyCreatedAnnotations()
        }
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init(annotationSQL: String? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT);
            INSERT INTO ZBKLIBRARYASSET VALUES(1,'asset-a','Alpha');
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: annotationSQL ?? Self.defaultAnnotationSQL)

            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static let defaultAnnotationSQL = """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONCREATIONDATE REAL
        );
        INSERT INTO ZAEANNOTATION VALUES
            (1,'asset-a',0,1,1),
            (2,'asset-a',0,1,2),
            (3,'asset-a',0,1,3),
            (4,'asset-a',0,1,4),
            (5,'asset-a',0,1,5),
            (6,'asset-a',0,1,6),
            (7,'asset-a',0,1,7),
            (8,'asset-a',0,1,8),
            (9,'asset-a',0,1,9),
            (10,'asset-a',0,1,10),
            (11,'asset-a',0,1,12),
            (12,'asset-orphan',0,2,12),
            (13,'asset-a',0,1,NULL),
            (20,'asset-a',0,3,100),
            (21,'asset-a',1,1,100),
            (22,'asset-a',NULL,1,100);
        """

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

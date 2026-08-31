import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("LibraryStatsTests")
struct LibraryStatsTests {
    @Test
    func statsReuseReadingPartitionsAndCanonicalUserAnnotations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let stats = try fixture.core.libraryStats()
        #expect(stats.totalBooks == 9)
        #expect(stats.finishedBooks == 1)
        #expect(stats.inProgressBooks == 1)
        #expect(stats.unstartedBooks == 7)
        #expect(stats.finishedBooks + stats.inProgressBooks + stats.unstartedBooks == stats.totalBooks)

        #expect(stats.totalUserAnnotations == 14)
        #expect(stats.orphanUserAnnotations == 5)
        #expect(stats.topAnnotatedBooks.map(\.book.localPK) == [1, 2, 4, 5, 3])
        #expect(stats.topAnnotatedBooks.map(\.userAnnotationCount) == [3, 2, 1, 1, 1])
        #expect(stats.topAnnotatedBooks.count == 5)
        #expect(stats.topAnnotatedBooks.allSatisfy { $0.userAnnotationCount <= stats.totalUserAnnotations })
    }

    @Test
    func duplicateCurrentAssetIdentityCountsAsOrphanInsteadOfPickingOneBook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let stats = try fixture.core.libraryStats()
        #expect(stats.orphanUserAnnotations == 5)
        #expect(stats.topAnnotatedBooks.contains { $0.book.assetID == "asset-dup" } == false)
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(
                Z_PK INTEGER PRIMARY KEY,
                ZASSETID TEXT,
                ZTITLE TEXT,
                ZISFINISHED INTEGER,
                ZREADINGPROGRESS REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
                (1,'asset-a','Alpha',1,1),
                (2,'asset-b','Beta',0,0.5),
                (3,'asset-c','Gamma',0,0),
                (4,'asset-d','Delta',NULL,NULL),
                (5,'asset-e','Epsilon',0,0),
                (6,'asset-f','Zeta',0,0),
                (7,'asset-dup','Dup A',0,0),
                (8,'asset-dup','Dup B',0,0),
                (9,NULL,'No Asset',0,0);
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONASSETID TEXT,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER
            );
            INSERT INTO ZAEANNOTATION VALUES
                (1,'asset-a',0,1),
                (2,'asset-a',0,1),
                (3,'asset-a',0,2),
                (4,'asset-b',0,1),
                (5,'asset-b',0,2),
                (6,'asset-c',0,1),
                (7,'asset-d',0,1),
                (8,'asset-e',0,1),
                (9,'asset-f',0,1),
                (10,'asset-orphan',0,1),
                (11,'asset-orphan',0,2),
                (12,'asset-dup',0,1),
                (13,'asset-dup',0,2),
                (14,NULL,0,1),
                (15,'asset-a',0,3),
                (16,'asset-a',1,1),
                (17,'asset-a',NULL,1);
            """)

            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
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

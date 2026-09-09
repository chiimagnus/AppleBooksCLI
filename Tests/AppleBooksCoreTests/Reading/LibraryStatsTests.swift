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

        #expect(stats.totalUserAnnotations == 15)
        #expect(stats.historicalAnnotationCount == 2)
        #expect(stats.unmappedAnnotationCount == 1)
        #expect(stats.ambiguousAnnotationCount == 2)
        #expect(stats.identityUnavailableAnnotationCount == 1)
        #expect(stats.orphanUserAnnotations == 6)
        #expect(stats.orphanUserAnnotations == stats.historicalAnnotationCount + stats.unmappedAnnotationCount + stats.ambiguousAnnotationCount + stats.identityUnavailableAnnotationCount)
        #expect(stats.topAnnotatedBooks.map(\.book.localPK) == [1, 2, 4, 5, 3])
        #expect(stats.topAnnotatedBooks.map(\.userAnnotationCount) == [3, 2, 1, 1, 1])
        #expect(stats.topAnnotatedBooks.count == 5)
        #expect(stats.topAnnotatedBooks.allSatisfy { $0.userAnnotationCount <= stats.totalUserAnnotations })
        #expect(stats.topAnnotatedBookSummaries.map(\.localPK) == [1, 2, 4, 5, 3])
        #expect(stats.topAnnotatedBookSummaries.map(\.annotationCount) == [3, 2, 1, 1, 1])
    }

    @Test
    func hundredThousandScaleStatsAndSparseAnnotatedCursorStayExact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("large-library.sqlite")
        let denseAnnotations = root.appendingPathComponent("dense-annotations.sqlite")
        let sparseAnnotations = root.appendingPathComponent("sparse-annotations.sqlite")
        let config = root.appendingPathComponent("config.json")
        try createLargeLibrary(library)
        try createLargeAnnotations(denseAnnotations, every: 1)
        try createLargeAnnotations(sparseAnnotations, every: 10_000)
        try Data("{}".utf8).write(to: config)

        let dense = try AppleBooks(
            libraryDB: library,
            annotationsDB: denseAnnotations,
            configurationFile: config
        )
        let stats = try dense.libraryStats()
        #expect(stats.totalBooks == 100_001)
        #expect(stats.finishedBooks == 0)
        #expect(stats.inProgressBooks == 0)
        #expect(stats.unstartedBooks == 100_001)
        #expect(stats.totalUserAnnotations == 100_001)
        #expect(stats.orphanUserAnnotations == 0)
        #expect(stats.topAnnotatedBookSummaries.map(\.localPK) == [1, 2, 3, 4, 5])
        #expect(stats.topAnnotatedBookSummaries.allSatisfy { $0.annotationCount == 1 })

        let sparse = try AppleBooks(
            libraryDB: library,
            annotationsDB: sparseAnnotations,
            configurationFile: config
        )
        var cursor: String?
        var localPKs: [Int64] = []
        repeat {
            let page = try sparse.annotatedBookSummaryPage(limit: 3, cursor: cursor)
            #expect(page.total == nil)
            localPKs += page.items.map(\.book.localPK)
            cursor = page.nextCursor
        } while cursor != nil
        #expect(localPKs == stride(from: Int64(1), through: 100_001, by: 10_000).map { $0 })
    }

    @Test
    func missingBookIdentitySchemaFailsClassificationInsteadOfPretendingUnmapped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = root.appendingPathComponent("library.sqlite")
        try Fixture.createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES (1,0,0);
        """)
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try Fixture.createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES (1,'missing-book-schema',0,1);
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        let core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)

        #expect(throws: AnnotationSourceClassificationError.schemaUnavailable) {
            _ = try core.libraryStats()
        }
    }

    @Test
    func duplicateCurrentAssetIdentityCountsAsOrphanInsteadOfPickingOneBook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let stats = try fixture.core.libraryStats()
        #expect(stats.ambiguousAnnotationCount == 2)
        #expect(stats.orphanUserAnnotations == 6)
        #expect(stats.topAnnotatedBooks.contains { $0.book.assetID == "asset-dup" } == false)
        #expect(stats.topAnnotatedBookSummaries.contains { $0.assetID == "asset-dup" } == false)
    }

    private func createLargeLibrary(_ url: URL) throws {
        try createDatabase(url, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZASSETID TEXT,
            ZTITLE TEXT,
            ZISFINISHED INTEGER,
            ZREADINGPROGRESS REAL
        );
        WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
        nums(n) AS (
            SELECT a.d + 10*b.d + 100*c.d + 1000*d.d + 10000*e.d + 100000*f.d
            FROM digits a, digits b, digits c, digits d, digits e, digits f
        )
        INSERT INTO ZBKLIBRARYASSET
        SELECT n + 1, printf('asset-%06d', n), printf('Title %06d', n), 0, 0
        FROM nums WHERE n <= 100000 ORDER BY n;
        CREATE INDEX idx_large_book_asset ON ZBKLIBRARYASSET(ZASSETID);
        """)
    }

    private func createLargeAnnotations(_ url: URL, every: Int) throws {
        try createDatabase(url, sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        WITH digits(d) AS (VALUES(0),(1),(2),(3),(4),(5),(6),(7),(8),(9)),
        nums(n) AS (
            SELECT a.d + 10*b.d + 100*c.d + 1000*d.d + 10000*e.d + 100000*f.d
            FROM digits a, digits b, digits c, digits d, digits e, digits f
        )
        INSERT INTO ZAEANNOTATION
        SELECT n + 1, printf('asset-%06d', n), 0, 1
        FROM nums WHERE n <= 100000 AND n % \(every) = 0 ORDER BY n;
        CREATE INDEX idx_large_annotation_asset ON ZAEANNOTATION(ZANNOTATIONASSETID);
        """)
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
            let oversizedIdentity = String(repeating: "x", count: 2_049)
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
                (18,'\(oversizedIdentity)',0,1),
                (15,'asset-a',0,3),
                (16,'asset-a',1,1),
                (17,'asset-a',NULL,1);
            """)

            let config = root.appendingPathComponent("config.json")
            let configData = try JSONSerialization.data(withJSONObject: [
                "historical_assets": [
                    "asset-orphan": ["title": "Historical Orphan", "author": "Fixture Author"],
                    "asset-dup": ["title": "Must Stay Ambiguous", "author": "Fixture Author"],
                ],
            ])
            try configData.write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        static func createDatabase(_ url: URL, sql: String) throws {
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

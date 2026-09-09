import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationQueriesTests")
struct AnnotationQueriesTests {
    @Test
    func canonicalUserScopeIsAnnotationFirstAndOrphanSafe() throws {
        let fixture = try fullFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queries = try makeQueries(fixture)

        let results = try queries.list()
        #expect(results.map { $0.annotation.localPK } == [6, 7, 8, 9, 1])
        #expect(results.map { $0.annotation.localPK }.contains(2) == false)
        #expect(results.map { $0.annotation.localPK }.contains(3) == false)
        #expect(results.map { $0.annotation.localPK }.contains(4) == false)
        #expect(results.map { $0.annotation.localPK }.contains(5) == false)

        #expect(sourceKind(results[0].source) == "historical")
        #expect(sourceKind(results[1].source) == "unmapped")
        #expect(sourceKind(results[2].source) == "historical")
        #expect(sourceKind(results[3].source) == "unmapped")
        #expect(sourceKind(results[4].source) == "current")

        #expect(results[0].annotation.selectedText == "")
        #expect(results[0].annotation.note == "historical note")
        #expect(results[3].annotation.representativeText == "keep me")
        #expect(results[1].annotation.style == 99)
        #expect(results[4].annotation.location?.rawCFI == "epubcfi(/6/8[ch]!/4/2,:1,:2)")
        #expect(results[4].annotation.physicalLocation == 4)
    }

    @Test
    func identityStyleTextAndDateFiltersKeepUserScope() throws {
        let fixture = try fullFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let queries = try makeQueries(fixture)

        #expect(try queries.getByUUID("u-current").map { $0.annotation.localPK } == [7, 1])
        #expect(try queries.getByLocalPK(2) == nil)
        #expect(try queries.getByLocalPK(3) == nil)
        #expect(try queries.getByLocalPK(4) == nil)
        #expect(try queries.getByLocalPK(5) == nil)
        #expect(try queries.byAssetID("asset-current").map { $0.annotation.localPK } == [1])
        #expect(try queries.byStyle(99).map { $0.annotation.localPK } == [7])
        #expect(try queries.byColorName("PURPLE").map { $0.annotation.localPK } == [6])
        #expect(try queries.searchHighlightedText("%_\\").map { $0.annotation.localPK } == [1])
        #expect(try queries.searchHighlightedText("%_\\", colorName: "yellow").map { $0.annotation.localPK } == [1])
        #expect(try queries.searchHighlightedText("%_\\", colorName: "green").isEmpty)
        #expect(try queries.searchNote("O'Reilly %_\\").map { $0.annotation.localPK } == [7])
        #expect(try queries.searchNote("historical", colorName: "purple").map { $0.annotation.localPK } == [6])

        let lower = try #require(CoreDataTime.date(from: 150))
        let upper = try #require(CoreDataTime.date(from: 180))
        #expect(try queries.created(lowerInclusive: lower, upperExclusive: upper).map { $0.annotation.localPK } == [6, 7, 8])
        #expect(throws: AnnotationQueryInputError.invalidDateRange) {
            _ = try queries.created(lowerInclusive: upper, upperExclusive: lower)
        }
        #expect(throws: AnnotationQueryInputError.unknownColor) {
            _ = try queries.byColorName("not-a-color")
        }
        #expect(throws: AnnotationQueryInputError.unknownColor) {
            _ = try queries.searchText("keep", colorName: "not-a-color")
        }
    }

    @Test
    func exactAnnotationIdentityPreservesEmbeddedNULBytes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("nul-annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONUUID TEXT,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES
            (1, CAST(X'750078' AS TEXT), CAST(X'610062' AS TEXT), 0, 1);
        """)
        let library = try database(at: root.appendingPathComponent("nul-library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (9, CAST(X'610062' AS TEXT));
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let queries = try AnnotationQueries(
            annotationConnection: SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: AppleBooksConfiguration(fileURL: config).historicalAssets
        )

        #expect(try queries.getByUUID("u\0x").map { $0.annotation.localPK } == [1])
        #expect(try queries.getByUUID("u").isEmpty)
        #expect(try queries.byAssetID("a\0b").map { $0.annotation.localPK } == [1])
        #expect(try queries.byAssetID("a").isEmpty)
    }

    @Test
    func aggregateCountsNeedNoAnnotationBodyColumnsAndBatchCapPrecedesSchemaInspection() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("aggregate.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'asset-a',0,1),
          (2,'asset-a',0,2),
          (3,'asset-a',0,3),
          (4,'asset-a',1,1),
          (5,NULL,0,1);
        """)
        let aggregate = AnnotationAggregateQueries(
            connection: try SQLiteConnection.readOnly(path: annotations.path)
        )

        #expect(try aggregate.totalUserAnnotations() == 3)
        #expect(try aggregate.userAnnotationCount(assetID: "asset-a") == 2)
        #expect(try aggregate.userAnnotationCounts(assetIDs: ["asset-a", "missing"]) == ["asset-a": 2])
        var groups: [UserAnnotationAssetCount] = []
        try aggregate.forEachUserAnnotationAssetCount { groups.append($0) }
        #expect(groups == [
            UserAnnotationAssetCount(rawAssetID: nil, count: 1),
            UserAnnotationAssetCount(rawAssetID: "asset-a", count: 2),
        ])

        let unrelated = try database(
            at: root.appendingPathComponent("unrelated.sqlite"),
            sql: "CREATE TABLE unrelated(id INTEGER);"
        )
        let invalid = AnnotationAggregateQueries(
            connection: try SQLiteConnection.readOnly(path: unrelated.path)
        )
        #expect(throws: AnnotationAggregateQueryError.batchTooLarge) {
            _ = try invalid.userAnnotationCounts(
                assetIDs: (0...100).map { "asset-\($0)" }
            )
        }
    }

    @Test
    func missingOptionalSortAndAssetColumnsDoNotDropCanonicalRows() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES (1,0,1),(3,0,2),(2,1,1),(4,NULL,1),(5,0,NULL);
        """)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let queries = try AnnotationQueries(
            annotationConnection: SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: try AppleBooksConfiguration(fileURL: config).historicalAssets
        )

        #expect(try queries.list().map { $0.annotation.localPK } == [3, 1])
        #expect(try queries.list().allSatisfy { $0.source == .unmapped })
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONCREATIONDATE"]
        )) {
            _ = try queries.created(lowerInclusive: Date())
        }
    }

    private func fullFixture() throws -> Fixture {
        let root = temporaryDirectory()
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONUUID TEXT,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONISUNDERLINE INTEGER,
            ZANNOTATIONSTYLE INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONCREATIONDATE REAL,
            ZANNOTATIONMODIFICATIONDATE REAL,
            ZANNOTATIONSELECTEDTEXT TEXT,
            ZANNOTATIONREPRESENTATIVETEXT TEXT,
            ZANNOTATIONNOTE TEXT,
            ZANNOTATIONLOCATION TEXT,
            ZPLABSOLUTEPHYSICALLOCATION INTEGER,
            ZPLLOCATIONRANGESTART INTEGER,
            ZPLLOCATIONRANGEEND INTEGER,
            ZFUTUREPROOFING5 TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'u-current','asset-current',0,0,3,1,100,100,'100%_\\ highlight','rep','', 'epubcfi(/6/8[ch]!/4/2,:1,:2)',4,1,2,'hint'),
          (2,'u-deleted','asset-current',1,0,1,1,200,300,'deleted','','',NULL,NULL,NULL,NULL,NULL),
          (3,'u-bookmark','asset-current',0,0,0,3,300,290,'','','',NULL,NULL,NULL,NULL,NULL),
          (4,'u-null-del','asset-current',NULL,0,1,1,190,280,'unknown deleted','','',NULL,NULL,NULL,NULL,NULL),
          (5,'u-null-type','asset-current',0,0,1,NULL,185,270,'unknown type','','',NULL,NULL,NULL,NULL,NULL),
          (6,'u-historical','asset-history',0,1,5,2,150,250,'','representative only','historical note',NULL,NULL,NULL,NULL,NULL),
          (7,'u-current','asset-missing',0,0,99,2,160,240,'','', 'O''Reilly %_\\',NULL,NULL,NULL,NULL,NULL),
          (8,'u-ambiguous','asset-dup',0,0,1,1,170,230,'ambiguous','','',NULL,NULL,NULL,NULL,NULL),
          (9,'u-noasset',NULL,0,0,2,1,180,220,'','keep me','',NULL,NULL,NULL,NULL,NULL);
        """)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (10,'asset-current','Current Book','Current Author'),
          (20,'asset-dup','Duplicate A','A'),
          (21,'asset-dup','Duplicate B','B');
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("""
        {
          "historical_assets": {
            "asset-history": {"title":"Historical Book","author":"History Author"},
            "asset-dup": {"title":"Historical Duplicate","author":"Fallback Author"}
          }
        }
        """.utf8).write(to: config)
        return Fixture(root: root, annotations: annotations, library: library, config: config)
    }

    private func makeQueries(_ fixture: Fixture) throws -> AnnotationQueries {
        AnnotationQueries(
            annotationConnection: try SQLiteConnection.readOnly(path: fixture.annotations.path),
            bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: fixture.library.path)),
            historicalAssets: try AppleBooksConfiguration(fileURL: fixture.config).historicalAssets
        )
    }

    private func sourceKind(_ source: AnnotationSource) -> String {
        switch source {
        case .currentLibrary: "current"
        case .historicalInferred: "historical"
        case .unmapped: "unmapped"
        }
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
        let annotations: URL
        let library: URL
        let config: URL
    }
}

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

        let results = try queries.semanticPage(AnnotationQueryRequest(limit: 100)).items
        #expect(results.map(\.localPK) == [6, 7, 8, 9, 1])
        #expect(results.map(\.localPK).contains(2) == false)
        #expect(results.map(\.localPK).contains(3) == false)
        #expect(results.map(\.localPK).contains(4) == false)
        #expect(results.map(\.localPK).contains(5) == false)

        #expect(results[0].source.kind == .historicalInferred)
        #expect(results[1].source.kind == .unmapped)
        #expect(results[2].source.kind == .ambiguousCurrent)
        #expect(results[3].source.kind == .unmapped)
        #expect(results[4].source.kind == .currentLibrary)

        #expect(results[0].selectedText == "")
        #expect(results[0].note == "historical note")
        #expect(results[3].representativeText == "keep me")
        #expect(results[1].style == 99)
        #expect(results[4].rawCFI == "epubcfi(/6/8[ch]!/4/2,:1,:2)")
        #expect(results[4].physicalLocation == 4)
    }

    @Test
    func semanticDatesSortInvalidRealAsNullAndExcludeItFromRanges() throws {
        let fixture = try fullFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setReal(.infinity, column: "ZANNOTATIONCREATIONDATE", localPK: 9, database: fixture.annotations)
        try setReal(.infinity, column: "ZANNOTATIONMODIFICATIONDATE", localPK: 9, database: fixture.annotations)
        let queries = try makeQueries(fixture)

        let listed = try queries.semanticPage(AnnotationQueryRequest(limit: 100)).items
        #expect(listed.map(\.localPK) == [6, 7, 8, 1, 9])
        #expect(listed.last?.createdAt == nil)
        #expect(listed.last?.modifiedAt == nil)

        let created = try queries.semanticPage(AnnotationQueryRequest(order: .created, limit: 100)).items
        #expect(created.last?.localPK == 9)

        let lower = try #require(CoreDataTime.date(from: 90))
        let upper = try #require(CoreDataTime.date(from: 200))
        #expect(try queries.semanticPage(
            AnnotationQueryRequest(createdAfter: lower, createdBefore: upper, limit: 100)
        ).items.map(\.localPK) == [6, 7, 8, 1])
        #expect(throws: AnnotationQueryRequestError.invalidDateRange) {
            _ = try AnnotationQueryRequest(
                createdAfter: Date(timeIntervalSince1970: CoreDataTime.maximumUnixSecondsExclusive)
            )
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

        let exact = try #require(try queries.semanticGetUniqueByUUID("u\0x"))
        #expect(exact.localPK == 1)
        #expect(exact.uuid == nil)
        #expect(try queries.semanticGetUniqueByUUID("u") == nil)
        #expect(try queries.exportAnnotations(assetID: "a\0b").map { $0.annotation.localPK } == [1])
        #expect(try queries.exportAnnotations(assetID: "a").isEmpty)
    }

    @Test
    func semanticAnnotationsBoundPreviewDetailAndIdentityWhileRawRowsStayFullFidelity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let body = String(repeating: "b", count: 1_048_576)
        let exactUUID = String(repeating: "u", count: 2_048)
        let oversizedUUID = String(repeating: "v", count: 2_049)
        let oversizedAssetID = String(repeating: "a", count: 2_049)
        let sourceTitle = String(repeating: "t", count: 1_048_576)
        let annotations = try database(at: root.appendingPathComponent("bounded-annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONUUID TEXT,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONSELECTEDTEXT TEXT,
            ZANNOTATIONREPRESENTATIVETEXT TEXT,
            ZANNOTATIONNOTE TEXT,
            ZANNOTATIONCREATIONDATE REAL,
            ZANNOTATIONMODIFICATIONDATE REAL
        );
        INSERT INTO ZAEANNOTATION VALUES
            (1, '\(exactUUID)', 'asset-current', 0, 1, '\(body)', '\(body)', '\(body)', 1, 2),
            (2, '\(oversizedUUID)', '\(oversizedAssetID)', 0, 1, 'small', 'small', 'small', 1, 1);
        """)
        let library = try database(at: root.appendingPathComponent("bounded-library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (10, 'asset-current', '\(sourceTitle)', 'author');
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let queries = AnnotationQueries(
            annotationConnection: try SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: try AppleBooksConfiguration(fileURL: config).historicalAssets
        )

        let previewPage = try queries.semanticPage(AnnotationQueryRequest(limit: 20))
        let preview = try #require(previewPage.items.first { $0.localPK == 1 })
        #expect(preview.uuid == exactUUID)
        #expect(preview.selectedText?.utf8.count == SQLiteSemanticTextBudget.preview)
        #expect(preview.representativeText?.utf8.count == SQLiteSemanticTextBudget.preview)
        #expect(preview.note?.utf8.count == SQLiteSemanticTextBudget.preview)
        #expect(Set(preview.byteTruncatedFields) == ["selectedText", "representativeText", "note"])
        #expect(preview.source.kind == .currentLibrary)
        #expect(preview.source.title?.utf8.count == SQLiteSemanticTextBudget.metadata)
        #expect(preview.source.byteTruncatedFields == ["title"])

        let detail = try #require(try queries.semanticGetByLocalPK(1))
        #expect(detail.selectedText?.utf8.count == SQLiteSemanticTextBudget.detail)
        #expect(detail.note?.utf8.count == SQLiteSemanticTextBudget.detail)
        #expect(detail.representativeText?.utf8.count == SQLiteSemanticTextBudget.preview)
        #expect(Set(detail.byteTruncatedFields) == ["selectedText", "representativeText", "note"])

        let unavailable = try #require(try queries.semanticGetByLocalPK(2))
        #expect(unavailable.uuid == nil)
        #expect(unavailable.rawAssetID == nil)
        #expect(unavailable.source.kind == .unmapped)
        #expect(unavailable.source.bookAssetID == nil)
        #expect(unavailable.source.bookLocalPK == nil)

        let rawRows = try queries.exportAnnotations()
        let raw = try #require(rawRows.first { $0.annotation.localPK == 1 })
        #expect(raw.annotation.selectedText?.utf8.count == body.utf8.count)
        #expect(raw.annotation.representativeText?.utf8.count == body.utf8.count)
        #expect(raw.annotation.note?.utf8.count == body.utf8.count)
        let rawUnavailable = try #require(rawRows.first { $0.annotation.localPK == 2 })
        #expect(rawUnavailable.annotation.uuid == oversizedUUID)
        #expect(rawUnavailable.annotation.rawAssetID == oversizedAssetID)
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
    func uniqueUUIDResolutionStopsAfterTwoRowsWhileAllMatchRemainsFullFidelity() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("duplicate.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONUUID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONSELECTEDTEXT TEXT
        );
        WITH RECURSIVE seq(x) AS (
            VALUES(1)
            UNION ALL
            SELECT x + 1 FROM seq WHERE x < 10001
        )
        INSERT INTO ZAEANNOTATION
        SELECT x, 'duplicate-uuid', 0, 1, CAST(X'FF' AS TEXT) FROM seq;
        """)
        let library = try database(
            at: root.appendingPathComponent("library.sqlite"),
            sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);"
        )
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let queries = AnnotationQueries(
            annotationConnection: try SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: try AppleBooksConfiguration(fileURL: config).historicalAssets
        )

        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try queries.semanticGetUniqueByUUID("duplicate-uuid")
        }
        #expect(throws: SQLiteRowError.invalidUTF8(column: "ZANNOTATIONSELECTEDTEXT")) {
            _ = try queries.exportAnnotations()
        }
    }

    @Test
    func canonicalOrderingFailsClosedWhenRequiredSortColumnsAreMissing() throws {
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

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONCREATIONDATE", "ZANNOTATIONMODIFICATIONDATE"]
        )) {
            _ = try queries.semanticPage(AnnotationQueryRequest())
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

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setReal(_ value: Double, column: String, localPK: Int64, database: URL) throws {
        var handle: OpaquePointer?
        let open = sqlite3_open(database.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, "UPDATE ZAEANNOTATION SET \(column) = ? WHERE Z_PK = ?", -1, &statement, nil)
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

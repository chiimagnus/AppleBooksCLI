import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationQueryPaginationTests")
struct AnnotationQueryPaginationTests {
    @Test
    func requestRejectsInvalidSelectorsTextDatesAndReadingScope() throws {
        #expect(throws: AnnotationQueryRequestError.invalidBookSelector) {
            _ = try AnnotationQueryRequest(book: .localPK(0))
        }
        #expect(throws: AnnotationQueryRequestError.invalidBookSelector) {
            _ = try AnnotationQueryRequest(book: .assetID(" bad "))
        }
        #expect(throws: AnnotationQueryRequestError.textFieldRequiresText) {
            _ = try AnnotationQueryRequest(textField: .note)
        }
        #expect(throws: AnnotationQueryRequestError.invalidText) {
            _ = try AnnotationQueryRequest(text: " \t\r\n")
        }
        #expect(throws: AnnotationQueryRequestError.invalidText) {
            _ = try AnnotationQueryRequest(text: String(repeating: "x", count: 513))
        }
        #expect(throws: AnnotationQueryRequestError.invalidDateRange) {
            _ = try AnnotationQueryRequest(
                createdAfter: Date(timeIntervalSince1970: CoreDataTime.maximumUnixSecondsExclusive)
            )
        }
        #expect(throws: AnnotationQueryRequestError.invalidDateRange) {
            _ = try AnnotationQueryRequest(createdAfter: date(20), createdBefore: date(10))
        }
        #expect(throws: AnnotationQueryRequestError.readingOrderRequiresBook) {
            _ = try AnnotationQueryRequest(order: .reading)
        }
    }

    @Test
    func combinedFiltersUseExactBookAsciiPresenceAndExactUnderlineSemantics() throws {
        let fixture = try orderedFixture()
        defer { fixture.remove() }

        let highlight = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            text: "needle",
            textField: .highlight,
            createdAfter: date(90),
            createdBefore: date(110),
            modifiedAfter: date(290),
            modifiedBefore: date(310),
            color: .green,
            underline: true,
            hasHighlight: true,
            hasNote: false,
            order: .modified
        ))
        #expect(highlight.items.map(\.localPK) == [1])
        #expect(highlight.items[0].isUnderline == true)

        let note = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .localPK(10),
            text: "needle",
            textField: .note,
            color: .green,
            underline: false,
            hasHighlight: false,
            hasNote: true,
            order: .created
        ))
        #expect(note.items.map(\.localPK) == [2])
        #expect(note.items[0].isUnderline == false)

        let nonCanonicalUnderline = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            underline: false,
            order: .created
        ))
        #expect(nonCanonicalUnderline.items.map(\.localPK).contains(2))
        #expect(nonCanonicalUnderline.items.map(\.localPK).contains(7))

        let unmapped = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-z"),
            order: .created
        ))
        #expect(unmapped.items.map(\.localPK) == [10])
    }

    @Test
    func createdAndModifiedKeysetsAreStableAndFingerprintBound() throws {
        let fixture = try orderedFixture()
        defer { fixture.remove() }

        let modified = try collect(fixture.queries, order: .modified)
        let created = try collect(fixture.queries, order: .created)
        #expect(modified == [3, 9, 7, 2, 1, 8])
        #expect(created == [8, 9, 7, 2, 3, 1])

        let first = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            order: .modified,
            limit: 2
        ))
        let cursor = try #require(first.nextCursor)
        #expect(throws: CursorPaginationError.filterMismatch) {
            _ = try fixture.queries.semanticPage(AnnotationQueryRequest(
                book: .assetID("asset-a"),
                color: .green,
                order: .modified,
                limit: 2,
                cursor: cursor
            ))
        }
    }

    @Test
    func annotationLibraryAndConfigGenerationChangesStaleOldCursor() throws {
        try assertStaleAfterMutation { fixture in
            try execute(fixture.annotations, "UPDATE ZAEANNOTATION SET ZANNOTATIONMODIFICATIONDATE=901 WHERE Z_PK=1")
        }
        try assertStaleAfterMutation { fixture in
            try execute(fixture.library, "UPDATE ZBKLIBRARYASSET SET ZTITLE='A title changed and lengthened' WHERE Z_PK=10")
        }
        try assertStaleAfterMutation { fixture in
            try Data("{\"historical_assets\":{\"asset-z\":{\"title\":\"Z\",\"author\":\"A\"}}}".utf8)
                .write(to: fixture.config)
        }
    }

    @Test
    func readingPageBoundsCandidatesAndOnlyMaterializesReturnedBodies() throws {
        let fixture = try readingFixture(rowCount: 30)
        defer { fixture.remove() }
        let instrumentation = AnnotationQueryInstrumentation()
        let page = try fixture.queries.semanticPage(
            AnnotationQueryRequest(
                book: .assetID("asset-a"),
                order: .reading,
                limit: 20
            ),
            instrumentation: instrumentation
        )

        #expect(page.items.map(\.localPK) == Array(1...20).map(Int64.init))
        #expect(page.hasMore)
        #expect(page.nextCursor != nil)
        #expect(instrumentation.readingCandidatePeak <= 21)
        #expect(instrumentation.materializedSummaryRows == 20)

        let rawLength = try scalarInt64(
            fixture.annotations,
            "SELECT length(CAST(ZANNOTATIONLOCATION AS BLOB)) FROM ZAEANNOTATION WHERE Z_PK=30"
        )
        #expect(rawLength > Int64(CFIResourcePolicy.maximumStructuralBytes))
    }

    @Test
    func readingContextGenerationStalesOnAvailabilityAndPackageChanges() throws {
        let unavailable = try readingFixture(rowCount: 6)
        defer { unavailable.remove() }
        let firstUnavailable = try unavailable.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            order: .reading,
            limit: 2
        ))
        let unavailableCursor = try #require(firstUnavailable.nextCursor)
        try makeDirectoryEPUB(at: unavailable.root.appendingPathComponent("reading.epub"))
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try unavailable.queries.semanticPage(AnnotationQueryRequest(
                book: .assetID("asset-a"),
                order: .reading,
                limit: 2,
                cursor: unavailableCursor
            ))
        }

        let changed = try readingFixture(rowCount: 6)
        defer { changed.remove() }
        let epub = changed.root.appendingPathComponent("reading.epub")
        try makeDirectoryEPUB(at: epub)
        let firstChanged = try changed.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            order: .reading,
            limit: 2
        ))
        let changedCursor = try #require(firstChanged.nextCursor)
        let package = epub.appendingPathComponent("OPS/package.opf")
        var packageData = try Data(contentsOf: package)
        packageData.append(contentsOf: "\n".utf8)
        try packageData.write(to: package)
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try changed.queries.semanticPage(AnnotationQueryRequest(
                book: .assetID("asset-a"),
                order: .reading,
                limit: 2,
                cursor: changedCursor
            ))
        }
    }

    @Test
    func hundredThousandReadingRowsKeepCandidateStateBoundedAcrossPages() throws {
        let rowCount = 100_001
        let fixture = try readingFixture(
            rowCount: rowCount,
            oversizedLastCFI: false,
            reverseReadingOrder: true
        )
        defer { fixture.remove() }
        let instrumentation = AnnotationQueryInstrumentation()
        var cursor: String?
        var actual: [Int64] = []
        for _ in 0..<3 {
            let page = try fixture.queries.semanticPage(
                AnnotationQueryRequest(
                    book: .assetID("asset-a"),
                    order: .reading,
                    limit: 20,
                    cursor: cursor
                ),
                instrumentation: instrumentation
            )
            actual.append(contentsOf: page.items.map(\.localPK))
            guard let nextCursor = page.nextCursor else {
                throw CursorPaginationError.internalContractFailure
            }
            cursor = nextCursor
        }

        let reference = (1...rowCount).map { value -> (Int64, EPUBAnnotationReadingKey) in
            let localPK = Int64(value)
            let position = rowCount - value + 1
            return (
                localPK,
                EPUBAnnotationReadingKey.make(
                    rawCFI: "epubcfi(/6/2[ch]!/4/\(position))",
                    createdAt: date(Double(value)),
                    localPK: localPK
                )
            )
        }.sorted { EPUBAnnotationReadingKey.lessThan($0.1, $1.1) }
            .prefix(actual.count)
            .map(\.0)

        #expect(actual == reference)
        #expect(Set(actual).count == actual.count)
        #expect(instrumentation.readingCandidatePeak <= 21)
        #expect(instrumentation.materializedSummaryRows == 60)
    }

    @Test
    func sharedReadingKeyIgnoresAssertionDigitsAndPinsFallbackBuckets() {
        let assertionA = EPUBAnnotationReadingKey.make(
            rawCFI: "epubcfi(/6/2[ch99]!/4/10[text123])",
            createdAt: date(100),
            localPK: 2
        )
        let assertionB = EPUBAnnotationReadingKey.make(
            rawCFI: "epubcfi(/6/2[ch1]!/4/10[text999])",
            createdAt: date(1),
            localPK: 1
        )
        #expect(EPUBAnnotationReadingKey.lessThan(assertionB, assertionA))
        #expect(EPUBAnnotationReadingKey.lessThan(assertionA, assertionB) == false)

        let mapped = EPUBAnnotationReadingKey.make(
            rawCFI: "epubcfi(/6/8[ch]!/4/2)",
            chapterOrder: ["ch": 1],
            createdAt: nil,
            localPK: 9
        )
        let structural = EPUBAnnotationReadingKey.make(
            rawCFI: "epubcfi(/6/2[other]!/4/2)",
            createdAt: nil,
            localPK: 1
        )
        let nilFallback = EPUBAnnotationReadingKey.make(rawCFI: nil, createdAt: nil, localPK: 3)
        let malformedFallback = EPUBAnnotationReadingKey.make(rawCFI: "not-a-cfi", createdAt: date(0), localPK: 4)
        let datedFallback = EPUBAnnotationReadingKey.make(rawCFI: nil, createdAt: date(1), localPK: 2)
        #expect(EPUBAnnotationReadingKey.lessThan(mapped, structural))
        #expect(EPUBAnnotationReadingKey.lessThan(structural, nilFallback))
        #expect(EPUBAnnotationReadingKey.lessThan(nilFallback, malformedFallback))
        #expect(EPUBAnnotationReadingKey.lessThan(malformedFallback, datedFallback))
    }

    private func collect(_ queries: AnnotationQueries, order: AnnotationQueryOrder) throws -> [Int64] {
        var cursor: String?
        var output: [Int64] = []
        repeat {
            let page = try queries.semanticPage(AnnotationQueryRequest(
                book: .assetID("asset-a"),
                order: order,
                limit: 2,
                cursor: cursor
            ))
            output.append(contentsOf: page.items.map(\.localPK))
            cursor = page.nextCursor
        } while cursor != nil
        return output
    }

    private func assertStaleAfterMutation(_ mutate: (Fixture) throws -> Void) throws {
        let fixture = try orderedFixture()
        defer { fixture.remove() }
        let first = try fixture.queries.semanticPage(AnnotationQueryRequest(
            book: .assetID("asset-a"),
            order: .modified,
            limit: 1
        ))
        let cursor = try #require(first.nextCursor)
        try mutate(fixture)
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try fixture.queries.semanticPage(AnnotationQueryRequest(
                book: .assetID("asset-a"),
                order: .modified,
                limit: 1,
                cursor: cursor
            ))
        }
    }

    private func orderedFixture() throws -> Fixture {
        let root = temporaryDirectory()
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
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
          ZANNOTATIONLOCATION TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'asset-a',0,1,1,1,100,300,' needle ','rep',' \t\r\n','epubcfi(/6/2[ch]!/4/2)'),
          (2,'asset-a',0,2,1,2,200,300,' \t\r\n','','needle note','epubcfi(/6/4[ch]!/4/2)'),
          (3,'asset-a',0,NULL,2,1,150,400,'needle','','note','epubcfi(/6/6[ch]!/4/2)'),
          (4,'asset-a',0,1,1,3,999,999,'needle','','note',NULL),
          (5,'asset-a',1,1,1,1,999,999,'needle','','note',NULL),
          (6,'asset-b',0,1,1,1,999,999,'needle','','note',NULL),
          (7,'asset-a',0,7,1,1,200,300,'','','','epubcfi(/6/8[ch]!/4/2)'),
          (8,'asset-a',0,0,1,1,250,NULL,'','','',NULL),
          (9,'asset-a',0,0,1,1,200,300,'','','',NULL),
          (10,'asset-z',0,0,1,1,50,50,'historical','','',NULL);
        """)
        let library = root.appendingPathComponent("library.sqlite")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (10,'asset-a','A','Author A','/tmp/applebookscli-query-missing.epub'),
          (20,'asset-b','B','Author B',NULL);
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return try fixture(root: root, annotations: annotations, library: library, config: config)
    }

    private func readingFixture(
        rowCount: Int,
        oversizedLastCFI: Bool = true,
        reverseReadingOrder: Bool = false
    ) throws -> Fixture {
        let root = temporaryDirectory()
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONCREATIONDATE REAL,
          ZANNOTATIONMODIFICATIONDATE REAL,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONLOCATION TEXT
        );
        """)
        var handle: OpaquePointer?
        let open = sqlite3_open(annotations.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "INSERT INTO ZAEANNOTATION VALUES(?, 'asset-a', 0, 1, ?, ?, ?, ?)",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: prepare, handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_exec(handle, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        let oversizedCFI = "epubcfi(/6/2[" + String(repeating: "x", count: CFIResourcePolicy.maximumStructuralBytes + 1_024) + "]!/4/2)"
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for value in 1...rowCount {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            guard sqlite3_bind_int64(statement, 1, Int64(value)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 2, Double(value)) == SQLITE_OK,
                  sqlite3_bind_double(statement, 3, Double(value)) == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
            guard sqlite3_bind_text(statement, 4, "safe", -1, transient) == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
            let position = reverseReadingOrder ? rowCount - value + 1 : value
            let cfi = oversizedLastCFI && value == rowCount
                ? oversizedCFI
                : "epubcfi(/6/2[ch]!/4/\(position))"
            guard cfi.withCString({ sqlite3_bind_text(statement, 5, $0, -1, transient) }) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
            }
        }
        guard sqlite3_exec(handle, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        // An invalid UTF-8 body outside page one proves the identity scan never decodes page-external bodies.
        try execute(annotations, "UPDATE ZAEANNOTATION SET ZANNOTATIONSELECTEDTEXT=CAST(X'FF' AS TEXT) WHERE Z_PK=25")

        let library = root.appendingPathComponent("library.sqlite")
        let epub = root.appendingPathComponent("reading.epub")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT, ZAUTHOR TEXT, ZPATH TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (10,'asset-a','A','Author','\(sql(epub.path))');
        """)
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        return try fixture(root: root, annotations: annotations, library: library, config: config)
    }

    private func makeDirectoryEPUB(at root: URL) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("META-INF"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("OPS"),
            withIntermediateDirectories: true
        )
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"ch\" href=\"ch.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"ch\"/></spine></package>".utf8)
            .write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body>chapter</body></html>".utf8)
            .write(to: root.appendingPathComponent("OPS/ch.xhtml"))
    }

    private func fixture(root: URL, annotations: URL, library: URL, config: URL) throws -> Fixture {
        let configuration = try AppleBooksConfiguration(fileURL: config)
        let queries = AnnotationQueries(
            annotationConnection: try SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: configuration.historicalAssets,
            configuration: configuration,
            configurationFileURL: config
        )
        return Fixture(root: root, annotations: annotations, library: library, config: config, queries: queries)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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

    private func execute(_ url: URL, _ sql: String) throws {
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

    private func scalarInt64(_ url: URL, _ sql: String) throws -> Int64 {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            throw SQLiteError.current(operation: .prepare, code: prepare, handle: handle)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteError.current(operation: .step, code: sqlite3_errcode(handle), handle: handle)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func date(_ coreSeconds: Double) -> Date {
        CoreDataTime.date(from: coreSeconds)!
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private struct Fixture {
        let root: URL
        let annotations: URL
        let library: URL
        let config: URL
        let queries: AnnotationQueries

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PDFSourceResolverTests")
struct PDFSourceResolverTests {
    @Test
    func pdfResourceTargetsRequireContentTypeAndFilterExactThree() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZCONTENTTYPE INTEGER,
          ZTITLE TEXT,
          ZPATH TEXT
        );
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1, 3, 'PDF', '/tmp/current.pdf'),
          (2, 1, 'EPUB', '/tmp/current.epub'),
          (3, NULL, 'Unknown', '/tmp/unknown.pdf');
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))

        var targets: [BookResourceTarget] = []
        try queries.forEachPDFResourceTarget { target, _ in
            targets.append(target)
            return true
        }
        #expect(targets.map(\.localPK) == [1])
        #expect(targets[0].contentType == 3)
        #expect(targets[0].path == "/tmp/current.pdf")

        let missingColumn = root.appendingPathComponent("missing-content-type.sqlite")
        try createDatabase(missingColumn, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZPATH TEXT);")
        let incomplete = BookQueries(connection: try SQLiteConnection.readOnly(path: missingColumn.path))
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(table: .books, columns: ["ZCONTENTTYPE"])) {
            try incomplete.forEachPDFResourceTarget { _, _ in true }
        }
    }

    @Test
    func boundedInventoryUsesBookIdentityThenOpaqueSourceIdentity() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let resolver = PDFSourceResolver(fallbackRoot: fixture.fallbackRoot)
        let queries = fixture.queries()

        let first = try resolver.inventoryPage(bookQueries: queries, limit: 2)
        #expect(first.items.map(\.bookAssetID) == ["asset-a", "asset-b"])
        #expect(first.items.allSatisfy { $0.pdfSourceID == nil })
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let rest = try resolver.inventoryPage(bookQueries: queries, limit: 100, cursor: cursor)
        #expect(rest.items.isEmpty == false)
        #expect(rest.items.allSatisfy { $0.bookAssetID == nil && $0.pdfSourceID != nil })
        #expect(rest.items.allSatisfy { item in
            guard let raw = item.pdfSourceID else { return false }
            return (try? PDFSourceID.parse(raw)) != nil
        })
        #expect(rest.items.contains { $0.title == "No Identity" && $0.provenance == .library })
        #expect(rest.items.contains { $0.title == "duplicate" && $0.provenance == .library })
        #expect(rest.items.contains { $0.title == "fallback-a" && $0.provenance == .fallback })
        #expect(rest.items.contains { $0.title == "fallback-hardlink" } == false)

        let all = first.items + rest.items
        let selectors = all.map { $0.bookAssetID ?? $0.pdfSourceID }
        #expect(selectors.allSatisfy { $0 != nil })
        #expect(Set(selectors.compactMap { $0 }).count == selectors.count)

        let again = try resolver.inventoryPage(bookQueries: queries, limit: 100)
        let firstOpaque = all.compactMap(\.pdfSourceID).first
        #expect(again.items.compactMap(\.pdfSourceID).contains(firstOpaque ?? ""))
    }

    @Test
    func opaqueSourceIDsAreStablePerSlotAndExactLookupConsumesEveryOpaqueKind() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let resolver = PDFSourceResolver(fallbackRoot: fixture.fallbackRoot)
        let queries = fixture.queries()
        let page = try resolver.inventoryPage(bookQueries: queries, limit: 100)
        let opaque = page.items.compactMap { item -> (PDFInventorySummary, PDFSourceID)? in
            guard let raw = item.pdfSourceID, let sourceID = try? PDFSourceID.parse(raw) else { return nil }
            return (item, sourceID)
        }
        #expect(opaque.count >= 3)

        for (item, sourceID) in opaque {
            let source = try #require(try resolver.resolve(sourceID: sourceID, bookQueries: queries))
            #expect(source.pdfSourceID == sourceID.rawValue)
            #expect(source.provenance == item.provenance)
        }

        let second = try resolver.inventoryPage(bookQueries: queries, limit: 100)
        #expect(page.items.compactMap(\.pdfSourceID) == second.items.compactMap(\.pdfSourceID))
        let fallbackBefore = try #require(page.items.first { $0.title == "fallback-a" }?.pdfSourceID)
        try Data("replacement-content".utf8).write(to: fixture.fallbackA)
        let afterReplacement = try resolver.inventoryPage(bookQueries: queries, limit: 100)
        #expect(afterReplacement.items.first { $0.title == "fallback-a" }?.pdfSourceID == fallbackBefore)
        let distinct = Set(page.items.compactMap(\.pdfSourceID))
        #expect(distinct.count == page.items.compactMap(\.pdfSourceID).count)
    }

    @Test
    func forcedSourceIDDigestCollisionFailsClosedForListAndExactLookup() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        try createEmptyFile(fallback.appendingPathComponent("a.pdf"))
        try createEmptyFile(fallback.appendingPathComponent("b.pdf"))
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZPATH TEXT,
          ZCONTENTTYPE INTEGER
        );
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        let resolver = PDFSourceResolver(
            fallbackRoot: fallback,
            sourceIDDigest: { _ in [UInt8](repeating: 0, count: PDFSourceID.digestByteCount) }
        )

        #expect(throws: PDFInventoryError.ambiguousSourceID) {
            _ = try resolver.inventoryPage(bookQueries: queries, limit: 100)
        }
        let colliding = try PDFSourceID.parse("pdf1_" + String(repeating: "0", count: 64))
        #expect(throws: PDFInventoryError.ambiguousSourceID) {
            _ = try resolver.resolve(sourceID: colliding, bookQueries: queries)
        }
    }

    @Test
    func fallbackScanRejectsSymlinksDirectoriesNestedEntriesAndLibraryHardlinkDuplicates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallbackRoot = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
        let libraryPDF = root.appendingPathComponent("library.pdf")
        try createEmptyFile(libraryPDF)
        let direct = fallbackRoot.appendingPathComponent("direct.pdf")
        try createEmptyFile(direct)
        let symlink = fallbackRoot.appendingPathComponent("linked.pdf")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: direct)
        try FileManager.default.createDirectory(
            at: fallbackRoot.appendingPathComponent("directory.pdf"),
            withIntermediateDirectories: false
        )
        let nested = fallbackRoot.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try createEmptyFile(nested.appendingPathComponent("nested.pdf"))
        let hardlink = fallbackRoot.appendingPathComponent("library-hardlink.pdf")
        #expect(link(libraryPDF.path, hardlink.path) == 0)

        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        INSERT INTO ZBKLIBRARYASSET VALUES(1,'asset','Library','\(sql(libraryPDF.path))',3);
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        let page = try PDFSourceResolver(fallbackRoot: fallbackRoot).inventoryPage(bookQueries: queries, limit: 100)
        #expect(page.items.count == 2)
        #expect(page.items.contains { $0.bookAssetID == "asset" })
        #expect(page.items.contains { $0.title == "direct" && $0.provenance == .fallback })
        #expect(page.items.contains { $0.title == "linked" || $0.title == "directory" || $0.title == "nested" || $0.title == "library-hardlink" } == false)

        let symlinkRoot = root.appendingPathComponent("fallback-link")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: fallbackRoot)
        let symlinkPage = try PDFSourceResolver(fallbackRoot: symlinkRoot).inventoryPage(bookQueries: queries, limit: 100)
        #expect(symlinkPage.items.count == 1)
        #expect(symlinkPage.items[0].bookAssetID == "asset")
    }

    @Test
    func cursorStalesWhenFallbackEntryOrLibraryMappingChanges() throws {
        let fixture = try InventoryFixture()
        defer { fixture.remove() }
        let resolver = PDFSourceResolver(fallbackRoot: fixture.fallbackRoot)
        let queries = fixture.queries()
        let first = try resolver.inventoryPage(bookQueries: queries, limit: 1)
        let cursor = try #require(first.nextCursor)

        try Data("replacement-with-different-size".utf8).write(to: fixture.fallbackA)
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try resolver.inventoryPage(bookQueries: queries, limit: 1, cursor: cursor)
        }

        let fresh = try resolver.inventoryPage(bookQueries: queries, limit: 1)
        let freshCursor = try #require(fresh.nextCursor)
        try execute(fixture.database, sql: "UPDATE ZBKLIBRARYASSET SET ZTITLE='Changed' WHERE Z_PK=1;")
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try resolver.inventoryPage(bookQueries: queries, limit: 1, cursor: freshCursor)
        }
    }

    @Test
    func tenThousandFallbackEntriesPageAndExactLookupWithoutDescriptorAccumulation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        for index in 0..<10_005 {
            try createEmptyFile(fallback.appendingPathComponent(String(format: "item-%05d.pdf", index)))
        }
        let database = root.appendingPathComponent("library.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        let resolver = PDFSourceResolver(fallbackRoot: fallback)

        let page = try resolver.inventoryPage(bookQueries: queries, limit: 20)
        #expect(page.items.count == 20)
        #expect(page.hasMore)
        #expect(page.nextCursor != nil)
        #expect(page.items.allSatisfy { $0.bookAssetID == nil && $0.pdfSourceID != nil })
        let sourceID = try PDFSourceID.parse(try #require(page.items.first?.pdfSourceID))
        let source = try resolver.resolve(sourceID: sourceID, bookQueries: queries)
        #expect(source?.pdfSourceID == sourceID.rawValue)
    }

    @Test
    func exactBookLookupDoesNotMaterializeUnrelatedOpaqueLibraryCandidates() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let selected = root.appendingPathComponent("selected.pdf")
        try createEmptyFile(selected)

        var rows: [String] = []
        rows.reserveCapacity(1_002)
        for index in 0..<1_001 {
            let url = root.appendingPathComponent(String(format: "opaque-%04d.pdf", index))
            try createEmptyFile(url)
            rows.append("(\(index + 1),NULL,'Opaque','\(sql(url.path))',3)")
        }
        rows.append("(2000,'selected','Selected','\(sql(selected.path))',3)")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        INSERT INTO ZBKLIBRARYASSET VALUES \(rows.joined(separator: ","));
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        var sourceIDDigestCalls = 0
        let resolver = PDFSourceResolver(
            fallbackRoot: root.appendingPathComponent("missing"),
            sourceIDDigest: { data in
                sourceIDDigestCalls += 1
                return PDFSourceID.defaultDigest(data)
            }
        )

        let source = try #require(try resolver.resolve(bookAssetID: "selected", bookQueries: queries))
        #expect(source.fileURL == selected.standardizedFileURL)
        #expect(source.bookSummary?.assetID == "selected")
        #expect(sourceIDDigestCalls == 0)
    }

    @Test
    func exactBookLookupRejectsCrossFormatDuplicateAssetIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let pdf = root.appendingPathComponent("selected.pdf")
        try createEmptyFile(pdf)
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'duplicate','PDF','\(sql(pdf.path))',3),
          (2,'duplicate','EPUB','/tmp/duplicate.epub',1);
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        let resolver = PDFSourceResolver(fallbackRoot: root.appendingPathComponent("missing"))

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try resolver.resolve(bookAssetID: "duplicate", bookQueries: queries)
        }
        let page = try resolver.inventoryPage(bookQueries: queries, limit: 20)
        #expect(page.items.count == 1)
        #expect(page.items[0].bookAssetID == nil)
        #expect(page.items[0].pdfSourceID != nil)
    }

    @Test
    func oversizedDatabasePathsAreUnavailableWithoutTruncation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let path4096 = "/" + String(repeating: "a", count: 4_095)
        let path4097 = "/" + String(repeating: "b", count: 4_096)
        let huge = "/" + String(repeating: "c", count: 2 * 1_024 * 1_024)
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (1,'a','\(sql(path4096))',3),
          (2,'b','\(sql(path4097))',3),
          (3,'c','\(sql(huge))',3);
        """)
        let queries = BookQueries(connection: try SQLiteConnection.readOnly(path: database.path))
        var observed: [String?] = []
        try queries.forEachPDFResourceTarget { target, _ in
            observed.append(target.path)
            return true
        }
        #expect(observed.count == 3)
        #expect(observed[0]?.utf8.count == 4_096)
        #expect(observed[1] == nil)
        #expect(observed[2] == nil)
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
        let page = try PDFSourceResolver(fallbackRoot: fallback).inventoryPage(bookQueries: queries, limit: 100)
        #expect(page.items.isEmpty)
    }

    @Test
    func exactBookPDFLookupDoesNotDecodeOtherRichPDFRows() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("selected.pdf")
        let other = root.appendingPathComponent("other.pdf")
        try createEmptyFile(pdf)
        try createEmptyFile(other)
        let database = root.appendingPathComponent("library.sqlite")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(database, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
        INSERT INTO ZBKLIBRARYASSET VALUES(1,'selected','Selected','\(sql(pdf.path))',3);
        INSERT INTO ZBKLIBRARYASSET VALUES(2,'other',CAST(X'80' AS TEXT),'\(sql(other.path))',3);
        """)
        try createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
        let core = try AppleBooks(
            libraryDB: database,
            annotationsDB: annotations,
            configurationFile: nil,
            collectionWriter: CollectionWriter(database: database),
            annotationWriter: AnnotationWriter(database: annotations),
            pdfSourceResolver: PDFSourceResolver(fallbackRoot: root.appendingPathComponent("missing"))
        )

        let source = try #require(try core.semanticPDFSource(bookAssetID: "selected"))
        #expect(source.fileURL == pdf.standardizedFileURL)
        #expect(source.bookSummary?.localPK == 1)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func createEmptyFile(_ url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw FixtureError.filesystem }
        close(descriptor)
    }

    private func createDatabase(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        let openResult = sqlite3_open(url.path, &handle)
        guard openResult == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: openResult, handle: handle)
        }
        defer { sqlite3_close_v2(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }

    private func execute(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.database }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
    }

    private func sql(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private final class InventoryFixture {
        let root: URL
        let fallbackRoot: URL
        let database: URL
        let uniqueA: URL
        let uniqueB: URL
        let noIdentity: URL
        let duplicate: URL
        let ambiguousA: URL
        let ambiguousB: URL
        let fallbackA: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true).standardizedFileURL
            fallbackRoot = root.appendingPathComponent("fallback", isDirectory: true)
            try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
            database = root.appendingPathComponent("library.sqlite")
            uniqueA = root.appendingPathComponent("unique-a.pdf")
            uniqueB = root.appendingPathComponent("unique-b.pdf")
            noIdentity = root.appendingPathComponent("no-id.pdf")
            duplicate = root.appendingPathComponent("duplicate.pdf")
            ambiguousA = root.appendingPathComponent("ambiguous-a.pdf")
            ambiguousB = root.appendingPathComponent("ambiguous-b.pdf")
            fallbackA = fallbackRoot.appendingPathComponent("fallback-a.pdf")
            for url in [uniqueA, uniqueB, noIdentity, duplicate, ambiguousA, ambiguousB, fallbackA] {
                let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard descriptor >= 0 else { throw FixtureError.filesystem }
                close(descriptor)
            }
            let hardlink = fallbackRoot.appendingPathComponent("fallback-hardlink.pdf")
            guard link(uniqueA.path, hardlink.path) == 0 else { throw FixtureError.filesystem }
            try Self.createDatabaseStatic(database, sql: """
            CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'asset-a','Unique A','\(Self.escape(uniqueA.path))',3),
              (2,'asset-b','Unique B','\(Self.escape(uniqueB.path))',3),
              (3,NULL,'No Identity','\(Self.escape(noIdentity.path))',3),
              (4,'dup-a','Duplicate A','\(Self.escape(duplicate.path))',3),
              (5,'dup-b','Duplicate B','\(Self.escape(duplicate.path))',3),
              (6,'ambiguous','Ambiguous A','\(Self.escape(ambiguousA.path))',3),
              (7,'ambiguous','Ambiguous B','\(Self.escape(ambiguousB.path))',3);
            """)
        }

        func queries() -> BookQueries {
            BookQueries(connection: try! SQLiteConnection.readOnly(path: database.path))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        private static func createDatabaseStatic(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
        }
    }

    private enum FixtureError: Error { case database, filesystem }
}

private func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "''")
}

private func createDatabaseStatic(_ url: URL, sql: String) throws {
    var handle: OpaquePointer?
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw NSError(domain: "db", code: 1) }
    defer { sqlite3_close_v2(handle) }
    guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "db", code: 2) }
}

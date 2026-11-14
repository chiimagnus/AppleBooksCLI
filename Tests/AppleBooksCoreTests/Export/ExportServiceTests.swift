import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ExportServiceTests")
struct ExportServiceTests {
    @Test
    func bulkEPUBExportDoesNotReadMissingEPUBContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missingEPUB = fixture.root.appendingPathComponent("missing.epub", isDirectory: true)
        try fixture.createLibrary([
            .init(pk: 1, assetID: "epub-current", title: "Current EPUB", contentType: 1, path: missingEPUB.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "epub-current", selectedText: "quote"),
        ])

        let bundle = try fixture.service().makeBundle(options: ExportOptions())

        #expect(bundle.groups.count == 1)
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.statistics.epubAnnotationCount == 1)
        guard case let .epubCurrent(book) = bundle.groups[0].source else {
            Issue.record("expected current EPUB group")
            return
        }
        #expect(book.assetID == "epub-current")
    }

    @Test
    func userScopeExcludesSystemRowsBeforeSelectionAndCountsOverlappingPresence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "presence", selectedText: "quote", note: "note"),
            .init(pk: 2, assetID: "presence", selectedText: nil, note: "note"),
            .init(pk: 3, assetID: "presence", selectedText: "quote"),
            .init(pk: 4, assetID: "presence", selectedText: " \t\r\n", note: " \t\r\n"),
            .init(pk: 5, assetID: "presence", selectedText: "system text", note: "system note", type: 3),
        ])
        let service = try fixture.service()
        for selectors: [ExportBookSelector] in [[], [.assetID("presence")]] {
            let bundle = try service.makeBundle(options: ExportOptions(bookSelectors: selectors))
            #expect(bundle.sourceTotals.epubAnnotationCount == 4)
            #expect(bundle.statistics.recordCount == 3)
            #expect(bundle.statistics.highlightCount == 2)
            #expect(bundle.statistics.noteCount == 2)
            let artifact = String(decoding: try renderJSON(bundle, exportedAt: Date(timeIntervalSince1970: 0)), as: UTF8.self)
            #expect(!artifact.contains("system text"))
            #expect(!artifact.contains("system note"))
            #expect(!artifact.contains("bookmarkCount"))
        }
    }

    @Test
    func archivalExportPreservesLargeAnnotationTextWithoutOrdinaryQueryBudgets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = String(repeating: "archive", count: 150_000)
        try fixture.createLibrary([
            .init(pk: 1, assetID: "archive-book", title: "Archive", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "archive-book", selectedText: body, note: body),
        ])

        let bundle = try fixture.service().makeBundle(options: ExportOptions())
        let record = try #require(bundle.groups.first?.records.first)
        let enriched = record.annotation
        #expect(enriched.annotation.selectedText == body)
        #expect(enriched.annotation.note == body)

        let data = try renderJSON(bundle, exportedAt: Date(timeIntervalSince1970: 0))
        #expect(data.count > body.utf8.count * 2)
    }

    @Test
    func documentIdentityMergesUnknownSourceSortsCanonicallyAndRejectsDigestCollision() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "z-book", title: "Same", contentType: 1, path: nil),
            .init(pk: 2, assetID: "a-book", title: "Same", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "z-book", selectedText: "z"),
            .init(pk: 2, assetID: "a-book", selectedText: "a"),
            .init(pk: 3, assetID: nil, selectedText: "unknown-one"),
            .init(pk: 4, assetID: nil, selectedText: "unknown-two"),
        ])

        let service = try fixture.service()
        let forward = try service.makeBundle(options: ExportOptions(
            bookSelectors: [.assetID("z-book"), .assetID("a-book")]
        ))
        let reverse = try service.makeBundle(options: ExportOptions(
            bookSelectors: [.assetID("a-book"), .assetID("z-book")]
        ))
        #expect(forward.groups.map(\.documentIdentity) == reverse.groups.map(\.documentIdentity))
        #expect(forward.groups.allSatisfy { $0.documentIdentity?.fullKey.hasPrefix("doc1_") == true })

        let bulk = try service.makeBundle(options: ExportOptions())
        let unknown = try #require(bulk.groups.first { group in
            if case .epubUnmapped(assetID: nil) = group.source { return true }
            return false
        })
        #expect(unknown.records.count == 2)
        #expect(bulk.groups.count == 3)

        var colliding = service
        colliding.documentIdentityDigest = { _ in Array(repeating: 0, count: 32) }
        #expect(throws: ExportServiceError.documentIdentityCollision) {
            _ = try colliding.makeBundle(options: ExportOptions())
        }
    }

    @Test
    func statisticsUseFinalSelectionWhileSourceTotalsRemainPreFilter() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "archive", selectedText: "first highlight"),
            .init(pk: 2, assetID: "archive", selectedText: "quote", note: "note"),
            .init(pk: 3, assetID: "archive", selectedText: "second highlight"),
        ])

        let bundle = try fixture.service().makeBundle(
            options: ExportOptions(
                hasHighlight: true,
                hasNote: false
            )
        )

        #expect(bundle.sourceTotals.epubAnnotationCount == 3)
        #expect(bundle.sourceTotals.epubDocumentCount == 1)
        #expect(bundle.statistics.recordCount == 2)
        #expect(bundle.statistics.highlightCount == 2)
        #expect(bundle.statistics.noteCount == 0)
        let selected = bundle.groups.flatMap(\.records).compactMap { record -> Int64? in
            return record.annotation.annotation.localPK
        }
        #expect(selected == [1, 3])
    }

    @Test
    func defaultReadingOrderSharesChapterMappingAndFallbackWithAnnotationQueries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let epub = try fixture.epub(name: "ordered.epub")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "ordered", title: "Ordered", contentType: 1, path: epub.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "ordered", selectedText: "second chapter", cfi: "epubcfi(/6/2[other]!/4/2:1)"),
            .init(pk: 2, assetID: "ordered", selectedText: "first chapter", cfi: "epubcfi(/6/10[chapter]!/4/2:1)"),
            .init(pk: 3, assetID: "ordered", selectedText: "no location", cfi: "invalid"),
        ])
        let service = try fixture.service()
        let options = try ExportOptions(bookSelectors: [.assetID("ordered")])
        let mapped = try service.makeBundle(options: options)
        let mappedPKs = mapped.groups.flatMap(\.records).compactMap { record -> Int64? in
            return record.annotation.annotation.localPK
        }
        #expect(mappedPKs == [2, 1, 3])
        let page = try #require(service.annotationQueries).semanticPage(AnnotationQueryRequest(
            book: .assetID("ordered"), order: .reading
        ))
        #expect(mappedPKs == page.items.map(\.localPK))
        let markdown = renderMarkdown(mapped)
        #expect(try #require(markdown.range(of: "first chapter")).lowerBound < #require(markdown.range(of: "second chapter")).lowerBound)

        try FileManager.default.removeItem(at: epub)
        let fallback = try service.makeBundle(options: options)
        let fallbackPKs = fallback.groups.flatMap(\.records).compactMap { record -> Int64? in
            return record.annotation.annotation.localPK
        }
        #expect(fallbackPKs == [1, 2, 3])
        let unavailablePage = try #require(service.annotationQueries).semanticPage(AnnotationQueryRequest(
            book: .assetID("ordered"), order: .reading
        ))
        #expect(fallbackPKs == unavailablePage.items.map(\.localPK))
    }

    @Test
    func localPKSelectorUsesExactCurrentBookIdentityWithoutNumericGuessing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 123, assetID: "stable-123", title: "PK Book", contentType: 1, path: nil),
            .init(pk: 1, assetID: "123", title: "Numeric Asset", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "stable-123", selectedText: "pk quote"),
            .init(pk: 2, assetID: "123", selectedText: "asset quote"),
        ])

        let byPK = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.localPK(123)], hasHighlight: true)
        )
        let byAsset = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.assetID("123")], hasHighlight: true)
        )

        let pkRows = byPK.groups.flatMap(\.records).compactMap { record -> Int64? in
            return record.annotation.annotation.localPK
        }
        let assetRows = byAsset.groups.flatMap(\.records).compactMap { record -> Int64? in
            return record.annotation.annotation.localPK
        }
        #expect(pkRows == [1])
        #expect(assetRows == [2])
    }

    @Test
    func stableAssetSelectorStillReachesHistoricalRowsWithoutCurrentBook() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "historical", selectedText: "history quote"),
        ])
        try fixture.createConfiguration(historical: [
            "historical": (title: "History", author: "Archive Author"),
        ])

        let bundle = try fixture.service().makeBundle(
            options: ExportOptions(bookSelectors: [.assetID("historical")], hasHighlight: true)
        )

        #expect(bundle.statistics.recordCount == 1)
        guard case let .epubHistorical(assetID, metadata) = try #require(bundle.groups.first).source else {
            Issue.record("expected historical EPUB group")
            return
        }
        #expect(assetID == "historical")
        #expect(metadata.title == "History")
    }

    @Test
    func missingStableSelectorFailsBeforeExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "present", title: "Present", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "present", selectedText: "quote"),
        ])

        #expect(throws: ExportServiceError.selectorNotFound) {
            _ = try fixture.service().makeBundle(
                options: ExportOptions(bookSelectors: [.assetID("missing")])
            )
        }
    }

    @Test
    func assetSelectorRejectsAmbiguousStableIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "duplicate", title: "One", contentType: 1, path: nil),
            .init(pk: 2, assetID: "duplicate", title: "Two", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "duplicate", selectedText: "quote"),
        ])

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.service().makeBundle(
                options: ExportOptions(
                        bookSelectors: [.assetID("duplicate")]
                )
            )
        }
    }

    @Test
    func exactEvidenceAndDuplicateSelectorsUseOneSourceOwner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "current", title: "Current", contentType: 1, path: nil),
            .init(pk: 2, assetID: "empty", title: "Empty", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "current", selectedText: "quote"),
            .init(pk: 2, assetID: "system", selectedText: "system", type: 3),
            .init(pk: 3, assetID: "unmapped", selectedText: "orphan"),
        ])
        try fixture.createConfiguration(historical: ["history": (title: "History", author: "Author")])
        let service = try fixture.service()
        let resolver = ExportSourceResolver(bookQueries: service.bookQueries)
        for selectors: [ExportBookSelector] in [
            [.assetID("current"), .localPK(1), .assetID("current")],
            [.localPK(1), .assetID("current")],
        ] {
            #expect(try resolver.resolve(selectors).map(\.key) == [.currentBook(1)])
            #expect(try service.makeBundle(options: ExportOptions(bookSelectors: selectors)).statistics.recordCount == 1)
        }
        for selectors: [ExportBookSelector] in [
            [.assetID("current"), .assetID("typo")], [.assetID("system")], [.localPK(999)],
        ] {
            #expect(throws: ExportServiceError.selectorNotFound) {
                _ = try service.makeBundle(options: ExportOptions(bookSelectors: selectors))
            }
        }
        for assetID in ["empty", "history"] {
            let bundle = try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID(assetID)]))
            #expect(bundle.statistics.recordCount == 0)
            }
        #expect(try resolver.resolve([.assetID("unmapped")]).map(\.key) == [.epubAsset("unmapped")])
        #expect(try resolver.resolve([.assetID("\u{e9}"), .assetID("e\u{301}")]).count == 2)
        #expect(try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID("unmapped")])).statistics.recordCount == 1)
    }

    @Test
    func pdfLibraryRowsAreExcludedFromEPUBExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.createLibrary([
            .init(pk: 1, assetID: "pdf-book", title: "PDF metadata", contentType: 3, path: nil),
            .init(pk: 2, assetID: "epub-book", title: "EPUB", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "pdf-book", selectedText: "must not export"),
            .init(pk: 2, assetID: "epub-book", selectedText: "epub truth"),
        ])
        let service = try fixture.service()
        #expect(throws: ExportServiceError.unsupportedBookFormat) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.assetID("pdf-book")]))
        }
        #expect(throws: ExportServiceError.unsupportedBookFormat) {
            _ = try service.makeBundle(options: ExportOptions(bookSelectors: [.localPK(1)]))
        }
        let bundle = try service.makeBundle(options: ExportOptions())
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.sourceTotals.epubAnnotationCount == 1)
        #expect(bundle.groups.first?.records.first?.annotation.annotation.selectedText == "epub truth")
    }

    private final class Fixture {
        static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let root: URL
        let libraryURL: URL
        let annotationsURL: URL
        let configurationURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            libraryURL = root.appendingPathComponent("library.sqlite")
            annotationsURL = root.appendingPathComponent("annotations.sqlite")
            configurationURL = root.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try createConfiguration()
        }

        func createLibrary(_ rows: [BookRow]) throws {
            var values: [String] = []
            for row in rows {
                values.append("(\(row.pk),\(sql(row.assetID)),\(sql(row.title)),\(row.contentType.map(String.init) ?? "NULL"),\(sql(row.path)))")
            }
            var sql = """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZCONTENTTYPE INTEGER,
              ZPATH TEXT
            );
            """
            if values.isEmpty == false {
                sql += "INSERT INTO ZBKLIBRARYASSET VALUES " + values.joined(separator: ",") + ";"
            }
            try createDatabase(libraryURL, sql: sql)
        }

        func createAnnotations(_ rows: [AnnotationRow]) throws {
            var values: [String] = []
            for row in rows {
                values.append("(\(row.pk),0,\(row.type.map(String.init) ?? "NULL"),\(sql(row.assetID)),\(sql(row.selectedText)),NULL,\(sql(row.note)),\(row.style.map(String.init) ?? "NULL"),\(row.underline.map { $0 ? "1" : "0" } ?? "NULL"),\(sql(row.cfi)),NULL)")
            }
            var sql = """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZANNOTATIONREPRESENTATIVETEXT TEXT,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONSTYLE INTEGER,
              ZANNOTATIONISUNDERLINE INTEGER,
              ZANNOTATIONLOCATION TEXT,
              ZANNOTATIONCREATIONDATE REAL
            );
            """
            if values.isEmpty == false {
                sql += "INSERT INTO ZAEANNOTATION VALUES " + values.joined(separator: ",") + ";"
            }
            try createDatabase(annotationsURL, sql: sql)
        }

        func createConfiguration(historical: [String: (title: String, author: String)] = [:]) throws {
            let entries = historical.mapValues { ["title": $0.title, "author": $0.author] }
            let data = try JSONSerialization.data(withJSONObject: ["historical_assets": entries])
            try data.write(to: configurationURL)
        }

        func epub(name: String) throws -> URL {
            let epub = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("""
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata>
                <dc:title>EPUB Enriched</dc:title>
                <dc:publisher>Publisher</dc:publisher>
              </metadata>
              <manifest>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="other" href="other.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/><itemref idref="other"/></spine>
            </package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>chapter</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            try Data("<html><body>other</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/other.xhtml"))
            try Self.png.write(to: epub.appendingPathComponent("OPS/cover.png"))
            return epub.standardizedFileURL.resolvingSymlinksInPath()
        }

        func service() throws -> ExportService {
            let libraryConnection = try SQLiteConnection.readOnly(path: libraryURL.path)
            let bookQueries = BookQueries(connection: libraryConnection)
            let configuration = try AppleBooksConfiguration(fileURL: configurationURL)
            let annotationQueries = AnnotationQueries(
                annotationConnection: try SQLiteConnection.readOnly(path: annotationsURL.path),
                bookQueries: bookQueries,
                historicalAssets: configuration.historicalAssets
            )
            return ExportService(annotationQueries: annotationQueries, bookQueries: bookQueries)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        private func sql(_ value: String?) -> String {
            guard let value else { return "NULL" }
            return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }

    }

    private struct BookRow {
        let pk: Int64
        let assetID: String?
        let title: String?
        let contentType: Int64?
        let path: String?
    }

    private struct AnnotationRow {
        let pk: Int64
        let assetID: String?
        let selectedText: String?
        let note: String?
        let type: Int64?
        let style: Int64?
        let underline: Bool?
        let cfi: String?

        init(
            pk: Int64,
            assetID: String?,
            selectedText: String?,
            note: String? = nil,
            type: Int64? = 1,
            style: Int64? = nil,
            underline: Bool? = nil,
            cfi: String? = nil
        ) {
            self.pk = pk
            self.assetID = assetID
            self.selectedText = selectedText
            self.note = note
            self.type = type
            self.style = style
            self.underline = underline
            self.cfi = cfi
        }
    }

    private enum FixtureError: Error {
        case database
    }
}

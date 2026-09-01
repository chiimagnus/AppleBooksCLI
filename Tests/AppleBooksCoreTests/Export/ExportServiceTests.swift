import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("ExportServiceTests")
struct ExportServiceTests {
    @Test
    func defaultEPUBExportDoesNotRequirePDFWorkerOrReadEPUBContent() throws {
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
        #expect(bundle.statistics.pdfHighlightCount == 0)
        #expect(bundle.warnings.isEmpty)
        #expect(bundle.groups[0].epubMetadata == nil)
        #expect(bundle.groups[0].epubCover == nil)
        guard case let .epubCurrent(book) = bundle.groups[0].source else {
            Issue.record("expected current EPUB group")
            return
        }
        #expect(book.assetID == "epub-current")
    }

    @Test
    func allSourceMergesCanonicalEPUBAndPDFAndKeepsFailuresAsWarnings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let goodPDF = try fixture.pdf(name: "good.pdf")
        _ = try fixture.pdf(name: "bad.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "epub-current", title: "Current EPUB", contentType: 1, path: nil),
            .init(pk: 2, assetID: "pdf-current", title: "Current PDF", contentType: 3, path: goodPDF.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "epub-current", selectedText: "epub"),
            .init(pk: 2, assetID: "pdf-current", selectedText: "must be excluded"),
            .init(pk: 3, assetID: "historical", selectedText: "history"),
            .init(pk: 4, assetID: "unmapped", selectedText: "orphan"),
        ])
        try fixture.createConfiguration(historical: [
            "historical": (title: "Historical", author: "Archive Author"),
        ])
        let worker = try fixture.worker()

        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(source: .all)
        )

        #expect(bundle.sourceTotals.epubDocumentCount == 3)
        #expect(bundle.sourceTotals.epubAnnotationCount == 3)
        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 2)
        #expect(bundle.sourceTotals.pdfSucceededDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfFailedDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfHighlightCount == 1)

        #expect(bundle.statistics.documentCount == 4)
        #expect(bundle.statistics.epubDocumentCount == 3)
        #expect(bundle.statistics.pdfDocumentCount == 1)
        #expect(bundle.statistics.recordCount == 4)
        #expect(bundle.statistics.epubAnnotationCount == 3)
        #expect(bundle.statistics.pdfHighlightCount == 1)
        #expect(bundle.statistics.highlightCount == 4)
        #expect(bundle.statistics.noteCount == 0)
        #expect(bundle.statistics.bookmarkCount == 0)
        #expect(bundle.statistics.historicalEPUBAnnotationCount == 1)
        #expect(bundle.statistics.unmappedEPUBAnnotationCount == 1)
        #expect(bundle.warnings.count == 1)
        guard case let .pdfFailure(failure) = try #require(bundle.warnings.first) else {
            Issue.record("expected PDF failure warning")
            return
        }
        #expect(failure.source.fileURL.lastPathComponent == "bad.pdf")
        #expect(failure.reason == .worker(.workerFailure(.unreadableDocument)))

        let epubPKs = bundle.groups.flatMap(\.records).compactMap { record -> Int64? in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
        #expect(Set(epubPKs) == [1, 3, 4])
        #expect(epubPKs.contains(2) == false)
        let pdfRecord = try #require(bundle.groups.flatMap(\.records).first { record in
            if case .pdf = record.payload { return true }
            return false
        })
        guard case let .pdf(source, highlight) = pdfRecord.payload else {
            Issue.record("expected PDF record")
            return
        }
        #expect(source.book?.assetID == "pdf-current")
        #expect(highlight.page == 2)
        #expect(highlight.text == "pdf text")
    }

    @Test
    func pdfFileSelectorFiltersInventoryBeforeWorkerInvocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try fixture.pdf(name: "selected.pdf")
        _ = try fixture.pdf(name: "unselected-bad.pdf")
        try fixture.createLibrary([])
        try fixture.createAnnotations([])
        let worker = try fixture.worker()

        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(
                source: .pdf,
                bookSelectors: [.pdfFile(selected)]
            )
        )

        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfSucceededDocumentCount == 1)
        #expect(bundle.sourceTotals.pdfFailedDocumentCount == 0)
        #expect(bundle.statistics.pdfDocumentCount == 1)
        #expect(bundle.warnings.isEmpty)
        #expect(try fixture.workerCallCount() == 1)
        guard case let .pdf(source) = try #require(bundle.groups.first).source else {
            Issue.record("expected PDF group")
            return
        }
        #expect(source.fileURL == selected)
    }

    @Test
    func explicitEPUBEnrichmentIsBestEffortAndNeverGuessesHistoricalOrUnmappedContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let validEPUB = try fixture.epub(name: "valid.epub")
        let brokenEPUB = fixture.root.appendingPathComponent("missing.epub", isDirectory: true)
        try fixture.createLibrary([
            .init(pk: 1, assetID: "valid", title: "Valid", contentType: 1, path: validEPUB.path),
            .init(pk: 2, assetID: "broken", title: "Broken", contentType: 1, path: brokenEPUB.path),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "valid", selectedText: "valid quote"),
            .init(pk: 2, assetID: "broken", selectedText: "broken quote"),
            .init(pk: 3, assetID: "historical", selectedText: "history quote"),
            .init(pk: 4, assetID: "unmapped", selectedText: "orphan quote"),
        ])
        try fixture.createConfiguration(historical: [
            "historical": (title: "History", author: "Archive Author"),
        ])

        let bundle = try fixture.service().makeBundle(
            options: ExportOptions(
                includeEPUBMetadata: true,
                cover: .inline
            )
        )

        let valid = try #require(bundle.groups.first { group in
            if case let .epubCurrent(book) = group.source { return book.assetID == "valid" }
            return false
        })
        #expect(valid.epubMetadata?.title == "EPUB Enriched")
        #expect(valid.epubMetadata?.publisher == "Publisher")
        #expect(valid.epubCover?.mediaType == "image/png")
        #expect(valid.epubCover?.data == Fixture.png)

        let broken = try #require(bundle.groups.first { group in
            if case let .epubCurrent(book) = group.source { return book.assetID == "broken" }
            return false
        })
        #expect(broken.records.count == 1)
        #expect(broken.epubMetadata == nil)
        #expect(broken.epubCover == nil)
        #expect(bundle.warnings.contains(.epubContentUnavailable(bookLocalPK: 2)))

        let historical = try #require(bundle.groups.first { group in
            if case let .epubHistorical(assetID, _) = group.source { return assetID == "historical" }
            return false
        })
        #expect(historical.epubMetadata == nil)
        #expect(historical.epubCover == nil)
        let unmapped = try #require(bundle.groups.first { group in
            if case let .epubUnmapped(assetID) = group.source { return assetID == "unmapped" }
            return false
        })
        #expect(unmapped.epubMetadata == nil)
        #expect(unmapped.epubCover == nil)
        #expect(bundle.statistics.recordCount == 4)
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
                kinds: [.highlight],
                skipFirstPerBook: 1
            )
        )

        #expect(bundle.sourceTotals.epubAnnotationCount == 3)
        #expect(bundle.sourceTotals.epubDocumentCount == 1)
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.statistics.highlightCount == 1)
        #expect(bundle.statistics.noteCount == 0)
        #expect(bundle.statistics.bookmarkCount == 0)
        let remaining = try #require(bundle.groups.first?.records.first)
        guard case let .epub(enriched) = remaining.payload else {
            Issue.record("expected EPUB record")
            return
        }
        #expect(enriched.annotation.localPK == 1)
    }

    @Test
    func missingStableSelectorReturnsEmptyBundleWithoutWorker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "unrelated.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "present", title: "Present", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "present", selectedText: "quote"),
        ])
        let worker = try fixture.worker()

        let bundle = try fixture.service(worker: worker).makeBundle(
            options: ExportOptions(
                source: .all,
                bookSelectors: [.assetID("missing")]
            )
        )

        #expect(bundle.groups.isEmpty)
        #expect(bundle.statistics.recordCount == 0)
        #expect(bundle.sourceTotals.epubAnnotationCount == 0)
        #expect(bundle.sourceTotals.pdfAttemptedDocumentCount == 0)
        #expect(bundle.warnings.isEmpty)
        #expect(try fixture.workerCallCount() == 0)
    }

    @Test
    func assetSelectorUsesExactStableIdentityAndAmbiguityFailsBeforeWorker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.pdf(name: "unrelated.pdf")
        try fixture.createLibrary([
            .init(pk: 1, assetID: "duplicate", title: "One", contentType: 1, path: nil),
            .init(pk: 2, assetID: "duplicate", title: "Two", contentType: 1, path: nil),
        ])
        try fixture.createAnnotations([
            .init(pk: 1, assetID: "duplicate", selectedText: "quote"),
        ])
        let worker = try fixture.worker()

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.service(worker: worker).makeBundle(
                options: ExportOptions(
                    source: .all,
                    bookSelectors: [.assetID("duplicate")]
                )
            )
        }
        #expect(try fixture.workerCallCount() == 0)
    }

    private final class Fixture {
        static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let root: URL
        let pdfRoot: URL
        let libraryURL: URL
        let annotationsURL: URL
        let configurationURL: URL
        let counterURL: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            pdfRoot = root.appendingPathComponent("pdfs", isDirectory: true)
            libraryURL = root.appendingPathComponent("library.sqlite")
            annotationsURL = root.appendingPathComponent("annotations.sqlite")
            configurationURL = root.appendingPathComponent("config.json")
            counterURL = root.appendingPathComponent("worker-calls.txt")
            try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
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
                values.append("(\(row.pk),0,\(row.type.map(String.init) ?? "NULL"),\(sql(row.assetID)),\(sql(row.selectedText)),NULL,\(sql(row.note)),\(row.style.map(String.init) ?? "NULL"),\(row.underline.map { $0 ? "1" : "0" } ?? "NULL"),\(sql(row.cfi)))")
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
              ZANNOTATIONLOCATION TEXT
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

        func pdf(name: String) throws -> URL {
            let url = pdfRoot.appendingPathComponent(name).standardizedFileURL
            try Data("synthetic pdf".utf8).write(to: url)
            return url.resolvingSymlinksInPath()
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
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8).write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>chapter</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            try Self.png.write(to: epub.appendingPathComponent("OPS/cover.png"))
            return epub.standardizedFileURL.resolvingSymlinksInPath()
        }

        func worker() throws -> URL {
            let worker = root.appendingPathComponent("fake-worker")
            let counter = shellQuote(counterURL.path)
            let script = """
            #!/bin/sh
            set -eu
            printf 'x' >> \(counter)
            IFS= read -r request || true
            case "$request" in
              *bad.pdf*|*unselected-bad.pdf*)
                printf '%s' '{"version":1,"status":"failure","errorCode":"unreadableDocument"}'
                ;;
              *)
                printf '%s' '{"version":1,"status":"success","highlights":[{"page":2,"traversalIndex":3,"bounds":{"x":1,"y":2,"width":30,"height":4},"quadrilateralPoints":[],"note":null,"pdfKitRGBA":[1,1,0,1],"presentationColor":{"color":"yellow","distance":0,"isApproximate":true},"text":"pdf text","textSource":"quadSelection","textIsApproximate":true}]}'
                ;;
            esac
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
            return worker
        }

        func workerCallCount() throws -> Int {
            guard FileManager.default.fileExists(atPath: counterURL.path) else { return 0 }
            return try String(contentsOf: counterURL, encoding: .utf8).count
        }

        func service(worker: URL? = nil) throws -> ExportService {
            let libraryConnection = try SQLiteConnection.readOnly(path: libraryURL.path)
            let bookQueries = BookQueries(connection: libraryConnection)
            let configuration = try AppleBooksConfiguration(fileURL: configurationURL)
            let annotationQueries = AnnotationQueries(
                annotationConnection: try SQLiteConnection.readOnly(path: annotationsURL.path),
                bookQueries: bookQueries,
                historicalAssets: configuration.historicalAssets
            )
            let pdfService = worker.map {
                PDFHighlightService(
                    bookQueries: bookQueries,
                    sourceResolver: PDFSourceResolver(fallbackRoot: pdfRoot),
                    workerClient: PDFWorkerClient(workerURL: $0, timeout: 2, terminationGrace: 0.05)
                )
            }
            return ExportService(
                annotationQueries: annotationQueries,
                bookQueries: bookQueries,
                configuration: configuration,
                pdfService: pdfService
            )
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

        private func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
        case permissions
    }
}

import AppleBooksCore
import Foundation
import SQLite3
import Testing

@Suite("ExportPublicAPITests")
struct ExportPublicAPITests {
    @Test
    func publicFacadeBuildsCanonicalBundleAndRendersEveryFormat() throws {
        let fixture = try Fixture(kind: .currentBook)
        defer { fixture.remove() }

        let core = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.configuration
        )
        let bundle = try core.exportBundle(
            options: ExportOptions(
                source: .epub,
                bookSelectors: [.assetID("asset-a")],
                kinds: [.highlight]
            )
        )

        #expect(bundle.statistics.documentCount == 1)
        #expect(bundle.statistics.recordCount == 1)
        #expect(bundle.statistics.epubAnnotationCount == 1)
        #expect(bundle.groups.count == 1)

        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let json = try JSONExporter.render(bundle, exportedAt: exportedAt)
        let jsonDocument = try JSONExporter.renderDocument(
            try #require(bundle.groups.first),
            from: bundle,
            exportedAt: exportedAt
        )
        let csv = CSVExporter.render(bundle)
        let html = HTMLExporter.render(bundle)
        let markdown = MarkdownAnnotationExporter.render(bundle)

        for data in [json, jsonDocument, csv] {
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(text.contains("public quote"))
            #expect(text.contains("deleted quote") == false)
        }
        #expect(html.contains("public quote"))
        #expect(html.contains("deleted quote") == false)
        #expect(markdown.contains("public quote"))
        #expect(markdown.contains("deleted quote") == false)
    }

    @Test
    func publicFacadeReturnsTypedPDFWorkerBoundary() throws {
        let fixture = try Fixture(kind: .currentBook)
        defer { fixture.remove() }

        let core = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.configuration
        )

        #expect(throws: ExportServiceError.pdfWorkerUnavailable) {
            _ = try core.exportBundle(
                options: ExportOptions(source: .pdf, kinds: [.highlight])
            )
        }
    }

    @Test
    func publicFacadeCannotBypassCompleteArchiveSafetyPreflight() throws {
        let fixture = try Fixture(kind: .unmappedNote)
        defer { fixture.remove() }

        let core = try AppleBooks(
            libraryDB: fixture.library,
            annotationsDB: fixture.annotations,
            configurationFile: fixture.configuration
        )

        #expect(throws: ExportSafetyValidationError.unmappedNotes(count: 1)) {
            _ = try core.exportBundle(options: ExportOptions(completeNotes: true))
        }
    }

    private final class Fixture {
        enum Kind {
            case currentBook
            case unmappedNote
        }

        let root: URL
        let library: URL
        let annotations: URL
        let configuration: URL

        init(kind: Kind) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            configuration = root.appendingPathComponent("config.json")

            let bookRows: String
            let annotationRows: String
            switch kind {
            case .currentBook:
                bookRows = "INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset-a','Public Book','Public Author',1);"
                annotationRows = """
                INSERT INTO ZAEANNOTATION VALUES
                  (1,'uuid-public','asset-a',0,0,1,1,10,20,'public quote','public representative',NULL,'epubcfi(/6/2[ch]!/4/2,:1,:2)',1,2,3,'ch'),
                  (2,'uuid-deleted','asset-a',1,0,1,1,11,21,'deleted quote','deleted representative',NULL,NULL,NULL,NULL,NULL,NULL);
                """
            case .unmappedNote:
                bookRows = ""
                annotationRows = """
                INSERT INTO ZAEANNOTATION VALUES
                  (1,'uuid-unmapped','missing-asset',0,0,1,1,10,20,'quoted text','representative','unmapped note',NULL,NULL,NULL,NULL,NULL);
                """
            }

            try Self.createDatabase(
                library,
                sql: """
                CREATE TABLE ZBKLIBRARYASSET(
                  Z_PK INTEGER PRIMARY KEY,
                  ZASSETID TEXT,
                  ZTITLE TEXT,
                  ZAUTHOR TEXT,
                  ZCONTENTTYPE INTEGER
                );
                \(bookRows)
                """
            )
            try Self.createDatabase(
                annotations,
                sql: """
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
                \(annotationRows)
                """
            )
            try Data("{\"historical_assets\":{}}".utf8).write(to: configuration)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let result = sqlite3_open(url.path, &handle)
            guard result == SQLITE_OK, let handle else {
                if let handle { sqlite3_close_v2(handle) }
                throw FixtureError.databaseOpen
            }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.databaseSetup
            }
        }
    }

    private enum FixtureError: Error {
        case databaseOpen
        case databaseSetup
    }
}

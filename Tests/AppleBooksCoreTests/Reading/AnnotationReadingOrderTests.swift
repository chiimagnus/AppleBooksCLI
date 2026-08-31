import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationReadingOrderTests")
struct AnnotationReadingOrderTests {
    @Test
    func knownTocChaptersSortBeforeUnknownWithStableChapterTies() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byPK = try fixture.core.annotationsInReadingOrder(bookLocalPK: 1)
        #expect(byPK.map { $0.annotation.localPK } == [2, 3, 1, 4, 5])

        let byAsset = try fixture.core.annotationsInReadingOrder(bookAssetID: "asset-one")
        #expect(byAsset == byPK)

        let limited = try fixture.core.annotationsInReadingOrder(bookLocalPK: 1, limit: 2)
        #expect(limited.map { $0.annotation.localPK } == [2, 3])
    }

    @Test
    func unavailableContentFallsBackToCreationOrderWithoutDroppingAnnotations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let annotations = try fixture.core.annotationsInReadingOrder(bookLocalPK: 2)
        #expect(annotations.map { $0.annotation.localPK } == [12, 11, 10])
        #expect(annotations.count == 3)
    }

    @Test
    func missingIdentityAndInvalidLimitFailAtTheirExplicitBoundaries() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.core.annotationsInReadingOrder(bookLocalPK: 3).isEmpty)
        #expect(try fixture.core.annotationsInReadingOrder(bookLocalPK: 999).isEmpty)
        #expect(try fixture.core.annotationsInReadingOrder(bookAssetID: "missing").isEmpty)
        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.core.annotationsInReadingOrder(bookAssetID: "asset-dup")
        }
        #expect(throws: QueryPaginationError.nonPositiveLimit) {
            _ = try fixture.core.annotationsInReadingOrder(bookLocalPK: 999, limit: 0)
        }
        #expect(throws: QueryPaginationError.nonPositiveLimit) {
            _ = try fixture.core.annotationsInReadingOrder(bookAssetID: "missing", limit: -1)
        }
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let epub = try Self.makeEPUB(in: root)

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(
                Z_PK INTEGER PRIMARY KEY,
                ZASSETID TEXT,
                ZTITLE TEXT,
                ZPATH TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
                (1,'asset-one','One','\(Self.sql(epub.path))'),
                (2,'asset-missing','Missing','/tmp/applebookscli-reading-order-missing.epub'),
                (3,NULL,'No Identity','/tmp/should-never-be-opened.txt'),
                (4,'asset-dup','Dup A',NULL),
                (5,'asset-dup','Dup B',NULL);
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONASSETID TEXT,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER,
                ZANNOTATIONCREATIONDATE REAL,
                ZANNOTATIONLOCATION TEXT
            );
            INSERT INTO ZAEANNOTATION VALUES
                (1,'asset-one',0,1,1,'epubcfi(/6/4[two]!/4/2,:0,:0)'),
                (2,'asset-one',0,1,5,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (3,'asset-one',0,2,5,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (4,'asset-one',0,1,0,'epubcfi(/6/8[missing]!/4/2,:0,:0)'),
                (5,'asset-one',0,1,2,NULL),
                (6,'asset-one',0,3,100,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (7,'asset-one',1,1,100,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (8,'asset-one',NULL,1,100,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (10,'asset-missing',0,1,4,'epubcfi(/6/4[two]!/4/2,:0,:0)'),
                (11,'asset-missing',0,1,1,'epubcfi(/6/2[one]!/4/2,:0,:0)'),
                (12,'asset-missing',0,1,NULL,NULL);
            """)

            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func makeEPUB(in parent: URL) throws -> URL {
            let root = parent.appendingPathComponent("reading-order.epub")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: root.appendingPathComponent("META-INF/container.xml"))
            try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"one\" href=\"one.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"two\" href=\"two.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine></package>".utf8)
                .write(to: root.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>one</body></html>".utf8).write(to: root.appendingPathComponent("OPS/one.xhtml"))
            try Data("<html><body>two</body></html>".utf8).write(to: root.appendingPathComponent("OPS/two.xhtml"))
            return root
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

        private static func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }
    }
}

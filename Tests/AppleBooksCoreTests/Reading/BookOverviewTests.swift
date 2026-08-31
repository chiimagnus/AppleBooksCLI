import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("BookOverviewTests")
struct BookOverviewTests {
    @Test
    func annotatedBooksUseCanonicalUserScopeCountsAndBookOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let overviews = try fixture.core.annotatedBooks()
        #expect(overviews.map(\.book.localPK) == [2, 1])
        #expect(overviews.map(\.userAnnotationCount) == [2, 1])

        let orphan = try #require(
            try fixture.core.listAnnotations().first { $0.annotation.localPK == 7 }
        )
        #expect(orphan.annotation.rawAssetID == "asset-orphan")
        #expect(orphan.source == .unmapped)
    }

    @Test
    func overviewSelectorsShareStableIdentityAndNilAssetCountsZero() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byPK = try #require(try fixture.core.bookOverview(localPK: 2))
        let byAsset = try #require(try fixture.core.bookOverview(assetID: "asset-a"))
        #expect(byPK == byAsset)
        #expect(byPK.userAnnotationCount == 2)

        let withoutAsset = try #require(try fixture.core.bookOverview(localPK: 3))
        #expect(withoutAsset.book.assetID == nil)
        #expect(withoutAsset.userAnnotationCount == 0)

        let withoutAnnotations = try #require(try fixture.core.bookOverview(assetID: "asset-none"))
        #expect(withoutAnnotations.userAnnotationCount == 0)
        #expect(try fixture.core.bookOverview(localPK: 999) == nil)
        #expect(try fixture.core.bookOverview(assetID: "missing") == nil)
    }

    @Test
    func stableAssetIdentityAmbiguityStillFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.core.bookOverview(assetID: "asset-dup")
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
                ZTITLE TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
                (1,'asset-b','Beta'),
                (2,'asset-a','alpha'),
                (3,NULL,'Gamma'),
                (4,'asset-none','Delta'),
                (5,'asset-dup','Dup A'),
                (6,'asset-dup','Dup B');
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
                (2,'asset-a',0,2),
                (3,'asset-a',0,3),
                (4,'asset-a',1,1),
                (5,'asset-a',NULL,1),
                (6,'asset-b',0,1),
                (7,'asset-orphan',0,1),
                (8,NULL,0,1);
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

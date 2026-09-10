import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("StableSelectorTests")
struct StableSelectorTests {
    @Test
    func stableStringSelectorsAreExactAndNeverGuessLocalPK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try fixture.core.semanticBookDetail(assetID: "book-12")?.localPK == 12)
        #expect(try fixture.core.semanticBookDetail(assetID: "BOOK-12")?.localPK == 13)
        #expect(try fixture.core.semanticCollection(collectionID: "collection-12")?.localPK == 12)
        #expect(try fixture.core.semanticCollection(collectionID: "COLLECTION-12")?.localPK == 13)
        #expect(try fixture.core.semanticAnnotation(uuid: "annotation-12")?.localPK == 12)
        #expect(try fixture.core.semanticAnnotation(uuid: "ANNOTATION-12")?.localPK == 15)

        #expect(try fixture.core.semanticBookDetail(assetID: "12abc") == nil)
        #expect(try fixture.core.semanticCollection(collectionID: "12abc") == nil)
        #expect(try fixture.core.semanticAnnotation(uuid: "12abc") == nil)
        #expect(try fixture.core.semanticCollection(collectionID: "collection-deleted") == nil)
        #expect(try fixture.core.semanticAnnotation(uuid: "annotation-deleted") == nil)
        #expect(try fixture.core.semanticAnnotation(uuid: "annotation-bookmark") == nil)
    }

    @Test
    func duplicateStableIdentityFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(throws: StableIdentityError.ambiguousBookAssetID) {
            _ = try fixture.core.semanticBookDetail(assetID: "book-dup")
        }
        #expect(throws: StableIdentityError.ambiguousCollectionID) {
            _ = try fixture.core.semanticCollection(collectionID: "collection-dup")
        }
        #expect(throws: StableIdentityError.ambiguousAnnotationUUID) {
            _ = try fixture.core.semanticAnnotation(uuid: "annotation-dup")
        }
    }

    @Test
    func annotationsByBookUseStableAssetIdentityAndExplicitLocalPKResolution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let user = try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .assetID("book-12"), limit: 100)
        )
        #expect(Set(user.items.map(\.localPK)) == [12, 20, 21])
        #expect(try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .assetID("BOOK-12"), limit: 100)
        ).items.map(\.localPK) == [15])

        let byPK = try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .localPK(12), limit: 100)
        )
        #expect(Set(byPK.items.map(\.localPK)) == [12, 20, 21])
        #expect(try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .assetID("12abc"), limit: 100)
        ).items.isEmpty)
        #expect(try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .localPK(999), limit: 100)
        ).items.isEmpty)
        #expect(try fixture.core.semanticAnnotationPage(
            AnnotationQueryRequest(book: .localPK(30), limit: 100)
        ).items.isEmpty)
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT COLLATE NOCASE,ZTITLE TEXT);
            INSERT INTO ZBKLIBRARYASSET VALUES
                (12,'book-12','Twelve'),
                (13,'BOOK-12','Uppercase Twelve'),
                (20,'book-dup','Duplicate A'),
                (21,'book-dup','Duplicate B'),
                (30,NULL,'No Asset');

            CREATE TABLE ZBKCOLLECTION(
                Z_PK INTEGER PRIMARY KEY,
                ZCOLLECTIONID TEXT COLLATE NOCASE,
                ZDELETEDFLAG INTEGER,
                ZTITLE TEXT
            );
            INSERT INTO ZBKCOLLECTION VALUES
                (12,'collection-12',0,'Shelf'),
                (13,'COLLECTION-12',0,'Uppercase Shelf'),
                (20,'collection-dup',0,'Duplicate A'),
                (21,'collection-dup',0,'Duplicate B'),
                (30,'collection-deleted',1,'Deleted');
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONUUID TEXT COLLATE NOCASE,
                ZANNOTATIONASSETID TEXT COLLATE NOCASE,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER,
                ZANNOTATIONCREATIONDATE REAL,
                ZANNOTATIONMODIFICATIONDATE REAL
            );
            INSERT INTO ZAEANNOTATION VALUES
                (12,'annotation-12','book-12',0,1,12,12),
                (13,'annotation-bookmark','book-12',0,3,13,13),
                (14,'annotation-null-type','book-12',0,NULL,14,14),
                (15,'ANNOTATION-12','BOOK-12',0,1,15,15),
                (20,'annotation-dup','book-12',0,1,20,20),
                (21,'annotation-dup','book-12',0,1,21,21),
                (30,'annotation-deleted','book-12',1,1,30,30);
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

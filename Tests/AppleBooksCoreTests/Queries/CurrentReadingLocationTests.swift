import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CurrentReadingLocationTests")
struct CurrentReadingLocationTests {
    @Test
    func queriesOnlyActiveType3RowsByRawAssetIdWithStableOrdering() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONMODIFICATIONDATE REAL,
            ZANNOTATIONLOCATION TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES
          (1,'asset',1,3,500,'deleted'),
          (2,'asset',0,1,600,'user-row'),
          (3,'asset',NULL,3,700,'unknown-delete'),
          (4,'asset',0,3,NULL,'null-date'),
          (5,'asset',0,3,100,'older'),
          (6,'asset',0,3,100,'epubcfi(/6/8[current]!/4/2,:1,:1)'),
          (7,'other',0,3,900,'other-asset');
        """)
        let queries = try ReadingQueries(
            connection: SQLiteConnection.readOnly(path: library.path),
            annotationConnection: SQLiteConnection.readOnly(path: annotations.path)
        )

        let position = try queries.currentPosition(rawAssetID: "asset")
        #expect(position?.localPK == 6)
        #expect(position?.type == 3)
        #expect(position?.rawAssetID == "asset")
        #expect(position?.location?.chapterID == "current")
        #expect(try queries.currentPosition(rawAssetID: "missing") == nil)
    }

    @Test
    func missingModificationColumnFallsBackToLocalPkDescending() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONASSETID TEXT,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER
        );
        INSERT INTO ZAEANNOTATION VALUES (1,'asset',0,3),(3,'asset',0,3),(2,'asset',0,1);
        """)
        let queries = try ReadingQueries(
            connection: SQLiteConnection.readOnly(path: library.path),
            annotationConnection: SQLiteConnection.readOnly(path: annotations.path)
        )
        #expect(try queries.currentPosition(rawAssetID: "asset")?.localPK == 3)
    }

    @Test
    func annotationConnectionIsExplicitlyRequired() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        let queries = try ReadingQueries(connection: SQLiteConnection.readOnly(path: library.path))
        #expect(throws: ReadingQueryConfigurationError.missingAnnotationConnection) {
            _ = try queries.currentPosition(rawAssetID: "asset")
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
}

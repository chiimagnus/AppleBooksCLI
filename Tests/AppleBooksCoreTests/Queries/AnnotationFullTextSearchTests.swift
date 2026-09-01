import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AnnotationFullTextSearchTests")
struct AnnotationFullTextSearchTests {
    @Test
    func groupedUserScopeIsAppliedBeforeStableLimit() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONSELECTEDTEXT TEXT,
            ZANNOTATIONREPRESENTATIVETEXT TEXT,
            ZANNOTATIONNOTE TEXT,
            ZANNOTATIONMODIFICATIONDATE REAL
        );
        INSERT INTO ZAEANNOTATION VALUES
          (100,0,3,'needle','','',1000),
          (99,0,3,'','needle','',999),
          (98,0,3,'','','needle',998),
          (97,1,1,'needle','','',997),
          (96,NULL,1,'needle','','',996),
          (95,0,NULL,'needle','','',995),
          (1,0,1,'needle','','',300),
          (2,0,2,'','needle','',200),
          (3,0,1,'','','needle',100),
          (4,0,1,'100%_\\ literal','','',50);
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

        #expect(try queries.searchText("needle", limit: 2).map { $0.annotation.localPK } == [1, 2])
        #expect(try queries.searchText("needle", limit: 2, offset: 1).map { $0.annotation.localPK } == [2, 3])
        #expect(try queries.searchText("needle").map { $0.annotation.localPK } == [1, 2, 3])
        #expect(try queries.searchText("%_\\").map { $0.annotation.localPK } == [4])
        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONSTYLE"]
        )) {
            _ = try queries.searchText("needle", colorName: "green")
        }
    }

    @Test
    func missingAnyFullTextColumnFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = try database(at: root.appendingPathComponent("annotations.sqlite"), sql: """
        CREATE TABLE ZAEANNOTATION(
            Z_PK INTEGER PRIMARY KEY,
            ZANNOTATIONDELETED INTEGER,
            ZANNOTATIONTYPE INTEGER,
            ZANNOTATIONSELECTEDTEXT TEXT,
            ZANNOTATIONNOTE TEXT
        );
        """)
        let library = try database(at: root.appendingPathComponent("library.sqlite"), sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let queries = try AnnotationQueries(
            annotationConnection: SQLiteConnection.readOnly(path: annotations.path),
            bookQueries: BookQueries(connection: SQLiteConnection.readOnly(path: library.path)),
            historicalAssets: try AppleBooksConfiguration(fileURL: config).historicalAssets
        )

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONREPRESENTATIVETEXT"]
        )) {
            _ = try queries.searchText("needle")
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

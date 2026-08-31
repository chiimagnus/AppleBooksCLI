import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("RecentlyModifiedAnnotationTests")
struct RecentlyModifiedAnnotationTests {
    @Test
    func returnsTenActiveRawRowsByModificationThenLocalPK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let results = try fixture.core.recentlyModifiedAnnotations()
        #expect(results.count == 10)
        #expect(results.map { $0.annotation.localPK } == [12, 11, 10, 9, 8, 7, 6, 5, 4, 3])
        #expect(results.contains { $0.annotation.type == 3 })
        #expect(results.contains { $0.annotation.type == nil })
        #expect(results.contains { $0.annotation.localPK == 13 } == false)
        #expect(results.contains { $0.annotation.localPK == 14 } == false)
    }

    @Test
    func equalModificationTimeUsesLocalPKNotCreationTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let results = try fixture.core.recentlyModifiedAnnotations()
        let tied = results.filter { [11, 12].contains($0.annotation.localPK) }
        #expect(tied.map { $0.annotation.localPK } == [12, 11])
        #expect(tied[0].annotation.createdAt! < tied[1].annotation.createdAt!)
    }

    @Test
    func missingModificationColumnFailsClosed() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY,ZANNOTATIONDELETED INTEGER,ZANNOTATIONTYPE INTEGER);
        INSERT INTO ZAEANNOTATION VALUES (1,0,1);
        """)
        let library = root.appendingPathComponent("library.sqlite")
        try createDatabase(library, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        let config = root.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)
        let core = try AppleBooks(libraryDB: library, annotationsDB: annotations, historicalConfig: config)

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .annotations,
            columns: ["ZANNOTATIONMODIFICATIONDATE"]
        )) {
            _ = try core.recentlyModifiedAnnotations()
        }
    }

    private final class Fixture {
        let root: URL
        let core: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            var rows: [String] = []
            for pk in 1...12 {
                let type = pk == 4 ? "3" : (pk == 5 ? "NULL" : "1")
                let modification = pk >= 11 ? "500" : String(pk * 10)
                let creation = pk == 11 ? "900" : (pk == 12 ? "100" : String(pk * 5))
                rows.append("(\(pk),0,\(type),\(creation),\(modification))")
            }
            rows.append("(13,1,1,1000,1000)")
            rows.append("(14,NULL,1,1000,1000)")
            try RecentlyModifiedAnnotationTests().createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER,
                ZANNOTATIONCREATIONDATE REAL,
                ZANNOTATIONMODIFICATIONDATE REAL
            );
            INSERT INTO ZAEANNOTATION VALUES \(rows.joined(separator: ","));
            """)

            let library = root.appendingPathComponent("library.sqlite")
            try RecentlyModifiedAnnotationTests().createDatabase(library, sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
            let config = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)
            core = try AppleBooks(libraryDB: library, annotationsDB: annotations, historicalConfig: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
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
}

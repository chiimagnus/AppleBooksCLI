import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("CollectionReadCommandTests")
struct CollectionReadCommandTests {
    private static let userCollectionID = "550E8400-E29B-41D4-A716-446655440000"

    @Test
    func helpExposesCursorPaginationAndRemovesOffset() {
        for command in ["list", "search", "books"] {
            let capture = Capture()
            let arguments = command == "search"
                ? ["collections", command, "--help"]
                : ["collections", command, "--help"]
            let code = CLIEntrypoint.run(arguments: arguments, output: capture.output)
            #expect(code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            #expect(capture.stdout.contains("--cursor"))
            #expect(capture.stdout.contains("--limit"))
            #expect(capture.stdout.contains("--offset") == false)
        }
    }

    @Test
    func listUsesCanonicalCursorOrderAndSemanticCapabilities() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "list", "--limit", "2"]
        )
        #expect(first.items.map(\.collectionID) == ["Want_To_Read_Collection_ID", Self.userCollectionID])
        #expect(first.items.map(\.title) == ["Alpha %_\\", "Beta"])
        #expect(first.items[0].canEditCollection == false)
        #expect(first.items[0].canEditMembership == true)
        #expect(first.items[1].canEditCollection == true)
        #expect(first.items[1].canEditMembership == true)
        #expect(first.hasMore)
        let cursor1 = try #require(first.nextCursor)

        let second = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "list", "--limit", "2", "--cursor", cursor1]
        )
        #expect(second.items.map(\.collectionID) == ["other-system", "123"])
        #expect(second.items.allSatisfy { !$0.canEditCollection && !$0.canEditMembership })
        #expect(second.hasMore)
        let cursor2 = try #require(second.nextCursor)

        let third = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "list", "--limit", "2", "--cursor", cursor2]
        )
        #expect(third.items.count == 1)
        #expect(third.items[0].collectionID == nil)
        #expect(third.items[0].localPK == 124)
        #expect(third.items[0].title == nil)
        #expect(third.hasMore == false)
        #expect(third.nextCursor == nil)
    }

    @Test
    func getUsesStableIdentityFirstAndOmitsPersistenceFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let byID = try fixture.runJSON(CollectionDetailResult.self, ["collections", "get", "123"])
        #expect(byID.collectionID == "123")
        #expect(byID.localPK == nil)

        let byPK = try fixture.runJSON(CollectionDetailResult.self, ["collections", "get", "--pk", "123"])
        #expect(byPK.collectionID == "other-system")
        #expect(byPK.localPK == nil)
        #expect(byPK.canEditCollection == false)
        #expect(byPK.canEditMembership == false)

        let raw = fixture.runRaw(["collections", "get", Self.userCollectionID])
        #expect(raw.code == CLIProcessExit.success.rawValue)
        let json = try #require(JSONSerialization.jsonObject(with: Data(raw.stdout.utf8)) as? [String: Any])
        #expect(json["details"] as? String == "detail beta")
        #expect(json["isHidden"] as? Bool == true)
        for internalKey in ["sortKey", "sortMode", "viewMode", "isPlaceholder", "isDeleted", "lastModificationDate", "localModificationDate"] {
            #expect(json[internalKey] == nil)
        }

        let conflict = fixture.runRaw(["collections", "get", "123", "--pk", "1"])
        #expect(conflict.code == CLIProcessExit.usageInvalid.rawValue)
        #expect(conflict.stdout.isEmpty)
    }

    @Test
    func searchIsLiteralBoundedAndCursorPaginatedBeforeIO() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let literal = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "search", "%_\\"]
        )
        #expect(literal.items.map(\.collectionID) == ["Want_To_Read_Collection_ID"])

        let first = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "search", "a", "--limit", "1"]
        )
        #expect(first.items.map(\.collectionID) == ["Want_To_Read_Collection_ID"])
        let cursor = try #require(first.nextCursor)
        let second = try fixture.runJSON(
            CollectionPageResult.self,
            ["collections", "search", "a", "--limit", "1", "--cursor", cursor]
        )
        #expect(second.items.map(\.collectionID) == [Self.userCollectionID])

        let tooManyGraphemes = String(repeating: "x", count: BoundedTextProfile.metadata.maximumGraphemes + 1)
        let tooManyBytes = "x" + String(repeating: "\u{0301}", count: BoundedTextProfile.metadata.maximumUTF8Bytes / 2 + 1)
        #expect(tooManyBytes.count == 1)
        #expect(tooManyBytes.utf8.count > BoundedTextProfile.metadata.maximumUTF8Bytes)
        for arguments in [
            ["collections", "search", ""],
            ["collections", "search", "   "],
            ["collections", "search", tooManyGraphemes],
            ["collections", "search", tooManyBytes],
            ["collections", "search", "a", "--limit", "0"],
            ["collections", "list", "--limit", "101"],
            ["collections", "list", "--cursor", "not+a+cursor"],
            ["collections", "list", "--offset", "1"],
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + Fixture.missingGlobals, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains("Database override") == false)
        }
    }

    @Test
    func booksUsesRelationOwnedDeduplicationAndCursorContinuation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try fixture.runJSON(
            CollectionBooksResult.self,
            ["collections", "books", Self.userCollectionID, "--limit", "2"]
        )
        #expect(first.items.map(\.assetID) == ["asset-b", "asset-b"])
        #expect(first.items.allSatisfy { $0.localPK == nil })
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let second = try fixture.runJSON(
            CollectionBooksResult.self,
            ["collections", "books", Self.userCollectionID, "--limit", "2", "--cursor", cursor]
        )
        #expect(second.items.map(\.assetID) == ["asset-a"])
        #expect(second.hasMore == false)
        #expect(second.nextCursor == nil)

        let byPK = try fixture.runJSON(
            CollectionBooksResult.self,
            ["collections", "books", "--pk", "1", "--limit", "100"]
        )
        #expect(byPK.items.map(\.assetID) == ["asset-b", "asset-b", "asset-a"])
    }

    @Test
    func collectionIdentityIsNeverTruncatedAndFallsBackToLocalPK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let exact = String(repeating: "i", count: PublicStableTokenPolicy.maximumUTF8Bytes)
        let oversized = exact + "j"
        try fixture.insertCollection(pk: 200, id: exact, title: "Edge A")
        try fixture.insertCollection(pk: 201, id: oversized, title: "Edge B")
        try fixture.insertCollection(pk: 202, id: "bad\0identity", title: "Edge C")
        try fixture.insertCollection(pk: 203, id: " leading-space", title: "Edge D")

        let exactResult = try fixture.runJSON(CollectionDetailResult.self, ["collections", "get", "--pk", "200"])
        #expect(exactResult.collectionID == exact)
        #expect(exactResult.localPK == nil)

        for pk in [201, 202, 203] {
            let result = try fixture.runJSON(CollectionDetailResult.self, ["collections", "get", "--pk", String(pk)])
            #expect(result.collectionID == nil)
            #expect(result.localPK == Int64(pk))
            #expect(result.canEditCollection == false)
            #expect(result.canEditMembership == false)
        }

        let invalidInput = fixture.runRaw(["collections", "get", oversized], globals: Fixture.missingGlobals)
        #expect(invalidInput.code == CLIProcessExit.usageInvalid.rawValue)
        #expect(invalidInput.stderr.contains("Database override") == false)
    }

    private final class Fixture {
        let root: URL
        let library: URL
        let annotations: URL

        static let missingGlobals = [
            "--library-db", "/definitely/missing/applebookscli-collections-library.sqlite",
            "--annotations-db", "/definitely/missing/applebookscli-collections-annotations.sqlite",
        ]

        var globals: [String] {
            ["--library-db", library.path, "--annotations-db", annotations.path]
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(library, sql: Self.librarySQL)
            try Self.createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
        }

        func runJSON<Value: Decodable>(_ type: Value.Type, _ arguments: [String]) throws -> Value {
            let capture = runRaw(arguments)
            #expect(capture.code == CLIProcessExit.success.rawValue)
            #expect(capture.stderr.isEmpty)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: Data(capture.stdout.utf8))
        }

        func runRaw(_ arguments: [String], globals override: [String]? = nil) -> (code: Int32, stdout: String, stderr: String) {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments + (override ?? globals), output: capture.output)
            return (code, capture.stdout, capture.stderr)
        }

        func insertCollection(pk: Int64, id: String?, title: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(library.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            var statement: OpaquePointer?
            let sql = "INSERT INTO ZBKCOLLECTION(Z_PK,ZCOLLECTIONID,ZTITLE,ZDELETEDFLAG) VALUES(?,?,?,0)"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw FixtureError.sqlite
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, pk)
            try Self.bind(id, to: statement, index: 2)
            try Self.bind(title, to: statement, index: 3)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func bind(_ value: String?, to statement: OpaquePointer, index: Int32) throws {
            guard let value else {
                guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw FixtureError.sqlite }
                return
            }
            let bytes = Array(value.utf8)
            let result = bytes.withUnsafeBytes { buffer in
                sqlite3_bind_text(
                    statement,
                    index,
                    buffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                    Int32(bytes.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
            guard result == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private static let librarySQL = """
        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          ZCOLLECTIONID TEXT,
          ZTITLE TEXT,
          ZDETAILS TEXT,
          ZDELETEDFLAG INTEGER,
          ZHIDDEN INTEGER,
          ZPLACEHOLDER INTEGER,
          ZSORTKEY INTEGER,
          ZSORTMODE INTEGER,
          ZVIEWMODE INTEGER,
          ZLASTMODIFICATION REAL,
          ZLOCALMODDATE REAL
        );
        CREATE TABLE ZBKCOLLECTIONMEMBER(
          Z_PK INTEGER PRIMARY KEY,
          ZCOLLECTION INTEGER,
          ZASSETID TEXT,
          ZSORTKEY REAL
        );
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT
        );
        INSERT INTO ZBKCOLLECTION VALUES
          (1,'550E8400-E29B-41D4-A716-446655440000','Beta','detail beta',0,1,0,100,6,2,10,11),
          (2,'Want_To_Read_Collection_ID','Alpha %_\\','want details',0,0,0,200,6,2,20,21),
          (3,'deleted','Deleted','private',1,0,0,300,6,2,30,31),
          (4,'unknown-state','Unknown','private',NULL,0,0,400,6,2,40,41),
          (123,'other-system','Gamma',NULL,0,0,NULL,NULL,NULL,NULL,NULL,NULL),
          (124,NULL,NULL,'nil identity',0,0,NULL,NULL,NULL,NULL,NULL,NULL),
          (126,'123','Numeric',NULL,0,0,NULL,NULL,NULL,NULL,NULL,NULL);
        INSERT INTO ZBKLIBRARYASSET VALUES
          (10,'asset-a','A','Ada'),
          (11,'asset-b','B','Bob'),
          (12,'asset-b','B duplicate','Bob');
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES
          (100,1,'asset-a',20),
          (101,1,'asset-b',10),
          (102,1,'missing-asset',15),
          (103,1,'asset-b',30),
          (104,1,NULL,5);
        """
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""
        var output: CLIOutput {
            CLIOutput(stdout: { [self] in stdout += $0 }, stderr: { [self] in stderr += $0 })
        }
    }

    private enum FixtureError: Error { case sqlite }
}

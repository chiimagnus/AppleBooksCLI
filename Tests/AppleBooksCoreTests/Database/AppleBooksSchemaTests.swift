import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("AppleBooksSchemaTests")
struct AppleBooksSchemaTests {
    @Test
    func capabilityMatrixKeepsRequiredAndOptionalColumnsSeparate() {
        #expect(SchemaCapability.bookBase.required == [AppleBooksSchema.Book.localPK])
        #expect(SchemaCapability.bookBase.optional.contains(AppleBooksSchema.Book.title))
        #expect(SchemaCapability.bookTitleSearch.required.contains(AppleBooksSchema.Book.title))
        #expect(SchemaCapability.readingRecentlyRead.required.contains(AppleBooksSchema.Book.lastOpenDate))
        #expect(SchemaCapability.collectionBase.required.contains(AppleBooksSchema.Collection.isDeleted))
        #expect(Set(SchemaCapability.collectionMembers.required) == Set([
            AppleBooksSchema.Member.localPK,
            AppleBooksSchema.Member.collection,
            AppleBooksSchema.Member.assetID,
        ]))
        #expect(Set(SchemaCapability.annotationUserBase.required) == Set([
            AppleBooksSchema.Annotation.localPK,
            AppleBooksSchema.Annotation.isDeleted,
            AppleBooksSchema.Annotation.type,
        ]))
        #expect(SchemaCapability.annotationByCreationDate.required.contains(AppleBooksSchema.Annotation.creationDate))
        #expect(SchemaCapability.currentPosition.required.contains(AppleBooksSchema.Annotation.assetID))
    }

    @Test
    func requiredColumnsFailClosedWhileOptionalColumnsMayBeAbsent() throws {
        let fixture = try database(sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY);")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)

        let base = try AppleBooksSchema.inspect(.bookBase, on: connection)
        #expect(base.contains(AppleBooksSchema.Book.localPK))
        #expect(base.contains(AppleBooksSchema.Book.title) == false)
        #expect(base.contains(AppleBooksSchema.Book.assetID) == false)

        #expect(throws: SchemaCompatibilityError.missingRequiredColumns(
            table: .books,
            columns: [AppleBooksSchema.Book.title]
        )) {
            _ = try AppleBooksSchema.inspect(.bookTitleSearch, on: connection)
        }
    }

    @Test
    func missingTableIsStructuredIncompatibility() throws {
        let fixture = try database(sql: "CREATE TABLE something_else(id INTEGER);")
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        let connection = try SQLiteConnection.readOnly(path: fixture.path)
        #expect(throws: SchemaCompatibilityError.missingTable(.annotations)) {
            _ = try AppleBooksSchema.inspect(.annotationUserBase, on: connection)
        }
    }

    private func database(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("schema.sqlite")
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

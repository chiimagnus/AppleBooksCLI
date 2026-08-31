import SQLite3
import XCTest
@testable import AppleBooksCore

final class AppleBooksLiveReadTests: XCTestCase {
    func testLiveStoresRemainReadOnlyAndQueriesPreserveP2Invariants() throws {
        guard ProcessInfo.processInfo.environment["APPLE_BOOKS_LIVE_READ"] == "1" else {
            throw XCTSkip("live Apple Books read gate is opt-in")
        }

        do {
            try runLiveReadGate()
        } catch {
            XCTFail("live Apple Books read gate failed")
        }
    }

    private func runLiveReadGate() throws {
        let discovered = try DatabaseDiscovery().discover()
        let library = try SQLiteConnection.readOnly(path: discovered.libraryDB.path)
        let annotations = try SQLiteConnection.readOnly(path: discovered.annotationsDB.path)

        guard sqlite3_db_readonly(library.handle, "main") == 1,
              sqlite3_db_readonly(annotations.handle, "main") == 1 else {
            XCTFail("a live Apple Books handle is not read-only")
            return
        }

        try assertQueryPragmaReadable(on: library)
        try assertQueryPragmaReadable(on: annotations)
        assertWriteRejected("UPDATE \(AppleBooksTable.books.rawValue) SET Z_PK = Z_PK WHERE 0", on: library, label: "library DML")
        assertWriteRejected("UPDATE \(AppleBooksTable.annotations.rawValue) SET Z_PK = Z_PK WHERE 0", on: annotations, label: "annotation DML")
        assertWriteRejected("CREATE TABLE __applebookscli_readonly_probe(value INTEGER)", on: library, label: "library DDL")
        assertWriteRejected("CREATE TABLE __applebookscli_readonly_probe(value INTEGER)", on: annotations, label: "annotation DDL")
        try assertJournalModeChangeRejected(on: library, label: "library journal mode")
        try assertJournalModeChangeRejected(on: annotations, label: "annotation journal mode")

        let bookQueries = BookQueries(connection: library)
        let readingQueries = ReadingQueries(connection: library)
        let baseBooks = try bookQueries.list()
        let finished = try readingQueries.finished()
        let inProgress = try readingQueries.inProgress()
        let unstarted = try readingQueries.unstarted()

        let base = Set(baseBooks.map(\.localPK))
        let finishedSet = Set(finished.map(\.localPK))
        let inProgressSet = Set(inProgress.map(\.localPK))
        let unstartedSet = Set(unstarted.map(\.localPK))
        XCTAssertTrue(finishedSet.isDisjoint(with: inProgressSet))
        XCTAssertTrue(finishedSet.isDisjoint(with: unstartedSet))
        XCTAssertTrue(inProgressSet.isDisjoint(with: unstartedSet))
        XCTAssertEqual(finishedSet.union(inProgressSet).union(unstartedSet), base)

        let canonicalCount = try activeUserAnnotationCount(on: annotations)
        let annotationQueries = AnnotationQueries(
            annotationConnection: annotations,
            bookQueries: bookQueries,
            historicalAssets: try HistoricalAssetMapping.loadDefault()
        )
        let enriched = try annotationQueries.list()
        XCTAssertEqual(enriched.count, canonicalCount)

        var currentLibraryAssetCounts: [String: Int] = [:]
        for book in baseBooks {
            if let assetID = book.assetID {
                currentLibraryAssetCounts[assetID, default: 0] += 1
            }
        }
        for item in enriched {
            let hasUniqueCurrentMatch = item.annotation.rawAssetID
                .flatMap { currentLibraryAssetCounts[$0] } == 1
            guard hasUniqueCurrentMatch == false else { continue }
            switch item.source {
            case .historicalInferred, .unmapped:
                break
            case .currentLibrary:
                XCTFail("non-unique or orphan annotation lost its orphan-safe enrichment state")
            }
        }

        try library.close()
        try annotations.close()
    }

    private func assertQueryPragmaReadable(on connection: SQLiteConnection) throws {
        let statement = try connection.prepare("PRAGMA schema_version")
        XCTAssertTrue(try statement.step())
    }

    private func assertWriteRejected(
        _ sql: String,
        on connection: SQLiteConnection,
        label: String
    ) {
        do {
            let statement = try connection.prepare(sql)
            while try statement.step() {}
            XCTFail("\(label) unexpectedly succeeded")
        } catch {
            // Expected: the live handle was opened with SQLITE_OPEN_READONLY.
        }
    }

    private func assertJournalModeChangeRejected(
        on connection: SQLiteConnection,
        label: String
    ) throws {
        let current = try journalMode(on: connection)
        let requested = current == "wal" ? "DELETE" : "WAL"
        assertWriteRejected("PRAGMA journal_mode=\(requested)", on: connection, label: label)
    }

    private func journalMode(on connection: SQLiteConnection) throws -> String {
        let statement = try connection.prepare("PRAGMA journal_mode")
        guard try statement.step(),
              let mode = try SQLiteRow(statement: statement).text("journal_mode") else {
            throw LiveReadGateError.missingJournalMode
        }
        return mode.lowercased()
    }

    private func activeUserAnnotationCount(on connection: SQLiteConnection) throws -> Int {
        let statement = try connection.prepare("""
        SELECT COUNT(*) AS row_count
        FROM \(AppleBooksTable.annotations.rawValue)
        WHERE \(AppleBooksSchema.Annotation.isDeleted) = 0
          AND \(AppleBooksSchema.Annotation.type) != 3
        """)
        guard try statement.step(),
              let count = try SQLiteRow(statement: statement).int64("row_count") else {
            throw LiveReadGateError.missingAnnotationCount
        }
        return Int(count)
    }
}

private enum LiveReadGateError: Error {
    case missingJournalMode
    case missingAnnotationCount
}

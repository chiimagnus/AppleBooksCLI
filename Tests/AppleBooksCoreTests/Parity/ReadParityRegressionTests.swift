import Foundation
import SQLite3
import XCTest
@testable import AppleBooksCore

final class ReadParityRegressionTests: XCTestCase {
    func testSourceAnchoredReadContractIsPureSwift() throws {
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/ReadParity")
        let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let libraryDB = temporaryDirectory.appendingPathComponent("library.sqlite")
        let annotationsDB = temporaryDirectory.appendingPathComponent("annotations.sqlite")
        try createDatabase(at: libraryDB, sqlURL: fixtureRoot.appendingPathComponent("library.sql"))
        try createDatabase(at: annotationsDB, sqlURL: fixtureRoot.appendingPathComponent("annotations.sql"))
        let config = temporaryDirectory.appendingPathComponent("config.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: config)

        let books = try AppleBooks(libraryDB: libraryDB, annotationsDB: annotationsDB, configurationFile: config)

        let listedBooks = try books.listBooks()
        XCTAssertEqual(listedBooks.map(\.localPK).sorted(), Array(1...12).map(Int64.init))
        let alpha = try XCTUnwrap(books.book(localPK: 1))
        XCTAssertEqual(alpha.assetID, "asset-1")
        XCTAssertEqual(alpha.title, "Alpha")
        XCTAssertEqual(alpha.genre, "Fiction")
        XCTAssertEqual(alpha.lastOpenDate?.timeIntervalSince1970, CoreDataTime.unixEpochOffset + 110)
        XCTAssertEqual(try books.books(matchingTitle: "Alpha").map(\.localPK), [1])
        XCTAssertEqual(try books.books(matchingGenre: "Fiction").map(\.localPK).sorted(), [1, 2])

        XCTAssertEqual(try books.listCollections().map(\.localPK).sorted(), [1, 2])
        XCTAssertEqual(try books.collection(localPK: 1)?.title, "Shelf A")

        let annotations = try books.listAnnotations().map(\.annotation)
        XCTAssertEqual(annotations.map(\.localPK).sorted(), [101, 102, 103, 104, 105])
        XCTAssertFalse(annotations.contains { $0.type == 3 })
        XCTAssertEqual(try books.annotations(matchingHighlightedText: "needle-selected").map { $0.annotation.localPK }, [101])
        XCTAssertEqual(try books.annotations(matchingNote: "needle-note").map { $0.annotation.localPK }, [102])
        XCTAssertEqual(try books.annotations(matchingText: "representative").map { $0.annotation.localPK }.sorted(), [101, 102, 103, 104, 105])

        let expectedColors: [String: Int64] = [
            "green": 101,
            "blue": 102,
            "yellow": 103,
            "pink": 104,
            "purple": 105,
        ]
        for (name, expectedID) in expectedColors {
            XCTAssertEqual(try books.annotations(colorName: name).map { $0.annotation.localPK }, [expectedID])
        }

        let lower = try XCTUnwrap(CoreDataTime.date(from: 102))
        let upper = try XCTUnwrap(CoreDataTime.date(from: 104))
        XCTAssertEqual(
            try books.annotations(createdAtOrAfter: lower, beforeExclusive: upper).map { $0.annotation.localPK }.sorted(),
            [102, 103]
        )

        XCTAssertEqual(try books.finishedBooks().map(\.localPK), [2])
        XCTAssertEqual(try books.unstartedBooks().map(\.localPK), [3])
        XCTAssertEqual(try books.booksInProgress().map(\.localPK).sorted(), [1, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        XCTAssertEqual(try books.recentlyReadBooks().map(\.localPK), [12, 11, 10, 9, 8, 7, 6, 5, 4, 3])
        XCTAssertEqual(try books.currentReadingLocation(forBookLocalPK: 1)?.localPK, 199)
    }

    private func createDatabase(at url: URL, sqlURL: URL) throws {
        let sql = try String(contentsOf: sqlURL, encoding: .utf8)
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
    }
}

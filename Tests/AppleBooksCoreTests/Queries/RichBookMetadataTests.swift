import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("RichBookMetadataTests")
struct RichBookMetadataTests {
    @Test
    func readsRichOptionalMetadataWithoutDisplayHeuristics() throws {
        let database = try makeDatabase(sql: """
        CREATE TABLE ZBKLIBRARYASSET(
            Z_PK INTEGER PRIMARY KEY,
            ZAUTHOR TEXT,
            ZEPUBID TEXT,
            ZMODIFICATIONDATE REAL,
            ZCOMMENTS TEXT,
            ZLANGUAGE TEXT,
            ZYEAR INTEGER,
            ZGENRES BLOB,
            ZCOVERURL TEXT,
            ZRELEASEDATE REAL,
            ZPAGECOUNT INTEGER,
            ZRATING REAL,
            ZREADINGPROGRESS REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES(
            1,
            '\u{E83A}UnknownAuthor',
            'epub-id-1',
            0,
            '',
            'zh-Hans',
            0,
            X'000102FF',
            'https://example.invalid/cover.jpg',
            0,
            0,
            0,
            0
        );
        """)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        let book = try #require(try queries(for: database).getByLocalPK(1))
        #expect(book.author == "\u{E83A}UnknownAuthor")
        #expect(book.normalizedAuthor == nil)
        #expect(book.epubID == "epub-id-1")
        #expect(book.modificationDate == CoreDataTime.date(from: 0))
        #expect(book.comments == "")
        #expect(book.language == "zh-Hans")
        #expect(book.year == 0)
        #expect(book.genresRaw == Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(book.coverURL == "https://example.invalid/cover.jpg")
        #expect(book.releaseDate == CoreDataTime.date(from: 0))
        #expect(book.pageCount == 0)
        #expect(book.rating == 0)
        #expect(book.readingProgressRaw == 0)
        #expect(book.readingProgressPercent == 0)
    }

    @Test
    func normalizedAuthorIsDerivedWithoutChangingRawAuthor() throws {
        let database = try makeDatabase(sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZAUTHOR TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES
            (1, '\u{E83A}UnknownAuthor'),
            (2, ' unknown '),
            (3, 'UNKNOWN AUTHOR'),
            (4, 'Ada\u{E123} Lovelace'),
            (5, '刘\u{E456}慈欣'),
            (6, '\u{E111}\u{E222}'),
            (7, 'Ursula K. Le Guin');
        """)
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        let books = try queries(for: database).list()
        #expect(books.map(\.author) == [
            "\u{E83A}UnknownAuthor",
            " unknown ",
            "UNKNOWN AUTHOR",
            "Ada\u{E123} Lovelace",
            "刘\u{E456}慈欣",
            "\u{E111}\u{E222}",
            "Ursula K. Le Guin",
        ])
        #expect(books.map(\.normalizedAuthor) == [
            nil,
            nil,
            nil,
            "Ada Lovelace",
            "刘慈欣",
            nil,
            "Ursula K. Le Guin",
        ])
    }

    @Test
    func eachRichColumnRemainsOptionalAndSqlNullDecodesToNil() throws {
        let definitions = [
            "ZEPUBID TEXT",
            "ZMODIFICATIONDATE REAL",
            "ZCOMMENTS TEXT",
            "ZLANGUAGE TEXT",
            "ZYEAR INTEGER",
            "ZGENRES BLOB",
            "ZCOVERURL TEXT",
            "ZRELEASEDATE REAL",
        ]

        for missingDefinition in definitions {
            let present = definitions.filter { $0 != missingDefinition }
            let database = try makeDatabase(sql: """
            CREATE TABLE ZBKLIBRARYASSET(
                Z_PK INTEGER PRIMARY KEY\(present.isEmpty ? "" : ",\n" + present.joined(separator: ",\n"))
            );
            INSERT INTO ZBKLIBRARYASSET(Z_PK) VALUES(1);
            """)
            defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

            let book = try #require(try queries(for: database).getByLocalPK(1))
            let missingColumn = missingDefinition.split(separator: " ", maxSplits: 1).first.map(String.init)!
            #expect(isNil(missingColumn, in: book))
            #expect(book.epubID == nil)
            #expect(book.modificationDate == nil)
            #expect(book.comments == nil)
            #expect(book.language == nil)
            #expect(book.year == nil)
            #expect(book.genresRaw == nil)
            #expect(book.coverURL == nil)
            #expect(book.releaseDate == nil)
        }
    }

    private func isNil(_ column: String, in book: Book) -> Bool {
        switch column {
        case "ZEPUBID": book.epubID == nil
        case "ZMODIFICATIONDATE": book.modificationDate == nil
        case "ZCOMMENTS": book.comments == nil
        case "ZLANGUAGE": book.language == nil
        case "ZYEAR": book.year == nil
        case "ZGENRES": book.genresRaw == nil
        case "ZCOVERURL": book.coverURL == nil
        case "ZRELEASEDATE": book.releaseDate == nil
        default: false
        }
    }

    private func queries(for url: URL) throws -> BookQueries {
        BookQueries(connection: try SQLiteConnection.readOnly(path: url.path))
    }

    private func makeDatabase(sql: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appendingPathComponent("books.sqlite")
        var database: OpaquePointer?
        let open = sqlite3_open(databaseURL.path, &database)
        guard open == SQLITE_OK, let database else {
            throw SQLiteError.current(operation: .open, code: open, handle: database)
        }
        defer { sqlite3_close_v2(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: database)
        }
        return databaseURL
    }
}

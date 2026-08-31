import Foundation

public enum QueryPaginationError: Error, Equatable, Sendable {
    case nonPositiveLimit
    case negativeOffset
}

public enum QueryDecodingError: Error, Equatable, Sendable {
    case nullRequiredColumn(String)
}

public enum BookSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case noSearchableColumns
}

func validatePagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 {
        throw QueryPaginationError.nonPositiveLimit
    }
    if offset < 0 {
        throw QueryPaginationError.negativeOffset
    }
}

struct BookQueries {
    private enum Filter {
        case none
        case localPK(Int64)
        case title(String)
        case genre(String)
        case combinedText(String)
        case contentPage
        case assetID(String)
    }

    private static let contentPagePredicate = "\(AppleBooksSchema.Book.contentType) IS NOT NULL"

    let connection: SQLiteConnection

    func list(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.none, capability: .bookBase, limit: limit, offset: offset)
    }

    func page(limit: Int? = nil, offset: Int = 0) throws -> Page<Book> {
        let effectiveLimit = try resolvedPageLimit(limit, default: 20, offset: offset)
        let total = try contentPageTotal()
        let items = try query(.contentPage, capability: .bookPage, limit: effectiveLimit, offset: offset)
        return Page(items: items, total: total, limit: effectiveLimit, offset: offset)
    }

    func getByLocalPK(_ localPK: Int64) throws -> Book? {
        try query(.localPK(localPK), capability: .bookBase, limit: 1, offset: 0).first
    }

    func searchTitle(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.title(text), capability: .bookTitleSearch, limit: limit, offset: offset)
    }

    func searchGenre(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.genre(text), capability: .bookGenreSearch, limit: limit, offset: offset)
    }

    func search(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        guard text.isEmpty == false else { throw BookSearchError.emptyQuery }
        return try query(.combinedText(text), capability: .bookBase, limit: limit, offset: offset)
    }

    func getByAssetID(_ assetID: String) throws -> [Book] {
        try query(.assetID(assetID), capability: .bookAssetLookup, limit: nil, offset: 0)
    }

    func getUniqueByAssetID(_ assetID: String) throws -> Book? {
        let matches = try getByAssetID(assetID)
        guard matches.count <= 1 else { throw StableIdentityError.ambiguousBookAssetID }
        return matches.first
    }

    func getForCurrentReadingLocation(_ localPK: Int64) throws -> Book? {
        try query(.localPK(localPK), capability: .bookCurrentReadingAssetLookup, limit: 1, offset: 0).first
    }

    func getForContent(_ localPK: Int64) throws -> Book? {
        try query(.localPK(localPK), capability: .bookContentPathLookup, limit: 1, offset: 0).first
    }

    private func query(
        _ filter: Filter,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [Book] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let combinedSearchColumns = [
            AppleBooksSchema.Book.title,
            AppleBooksSchema.Book.author,
            AppleBooksSchema.Book.genre,
        ].filter(schema.contains)
        if case .combinedText = filter, combinedSearchColumns.isEmpty {
            throw BookSearchError.noSearchableColumns
        }
        let projection = [AppleBooksSchema.Book.localPK] + AppleBooksSchema.Book.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue)"

        switch filter {
        case .none:
            break
        case .localPK:
            sql += " WHERE \(AppleBooksSchema.Book.localPK) = ?"
        case .title:
            sql += " WHERE \(AppleBooksSchema.Book.title) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        case .genre:
            sql += " WHERE \(AppleBooksSchema.Book.genre) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        case .combinedText:
            let clauses = combinedSearchColumns.map { "\($0) LIKE ? ESCAPE '\\' COLLATE NOCASE" }
            sql += " WHERE (\(clauses.joined(separator: " OR ")))"
        case .contentPage:
            sql += " WHERE \(Self.contentPagePredicate)"
        case .assetID:
            sql += " WHERE \(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY"
        }

        var order: [String] = []
        if schema.contains(AppleBooksSchema.Book.title) {
            order += [
                "\(AppleBooksSchema.Book.title) IS NULL",
                "\(AppleBooksSchema.Book.title) COLLATE NOCASE",
            ]
        }
        if schema.contains(AppleBooksSchema.Book.assetID) {
            order += [
                "\(AppleBooksSchema.Book.assetID) IS NULL",
                AppleBooksSchema.Book.assetID,
            ]
        }
        order.append(AppleBooksSchema.Book.localPK)
        sql += " ORDER BY \(order.joined(separator: ", "))"

        if limit != nil {
            sql += " LIMIT ? OFFSET ?"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
        }

        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        switch filter {
        case .none:
            break
        case let .localPK(value):
            try statement.bind(value, at: index)
            index += 1
        case let .title(value), let .genre(value):
            try statement.bind(literalContainsPattern(value), at: index)
            index += 1
        case let .combinedText(value):
            let pattern = literalContainsPattern(value)
            for _ in combinedSearchColumns {
                try statement.bind(pattern, at: index)
                index += 1
            }
        case .contentPage:
            break
        case let .assetID(value):
            try statement.bind(value, at: index)
            index += 1
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
            try statement.bind(Int64(offset), at: index + 1)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: index)
        }

        var books: [Book] = []
        while try statement.step() {
            books.append(try decode(SQLiteRow(statement: statement), schema: schema))
        }
        return books
    }

    private func contentPageTotal() throws -> Int {
        _ = try AppleBooksSchema.inspect(.bookPage, on: connection)
        let statement = try connection.prepare(
            "SELECT COUNT(*) AS count FROM \(AppleBooksTable.books.rawValue) WHERE \(Self.contentPagePredicate)"
        )
        guard try statement.step(),
              let count = try SQLiteRow(statement: statement).int64("count"),
              count >= 0 else {
            throw QueryDecodingError.nullRequiredColumn("count")
        }
        return Int(count)
    }

    func decode(_ row: SQLiteRow, schema: SchemaAvailability) throws -> Book {
        guard let localPK = try row.int64(AppleBooksSchema.Book.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }

        func text(_ column: String) throws -> String? {
            schema.contains(column) ? try row.text(column) : nil
        }
        func int64(_ column: String) throws -> Int64? {
            schema.contains(column) ? try row.int64(column) : nil
        }
        func double(_ column: String) throws -> Double? {
            schema.contains(column) ? try row.double(column) : nil
        }
        func blob(_ column: String) throws -> Data? {
            schema.contains(column) ? try row.blob(column) : nil
        }
        func bool(_ column: String) throws -> Bool? {
            try int64(column).map { $0 != 0 }
        }
        func date(_ column: String) throws -> Date? {
            CoreDataTime.date(from: try double(column))
        }

        return Book(
            localPK: localPK,
            assetID: try text(AppleBooksSchema.Book.assetID),
            title: try text(AppleBooksSchema.Book.title),
            author: try text(AppleBooksSchema.Book.author),
            description: try text(AppleBooksSchema.Book.description),
            epubID: try text(AppleBooksSchema.Book.epubID),
            genre: try text(AppleBooksSchema.Book.genre),
            genresRaw: try blob(AppleBooksSchema.Book.genres),
            comments: try text(AppleBooksSchema.Book.comments),
            language: try text(AppleBooksSchema.Book.language),
            year: try int64(AppleBooksSchema.Book.year),
            contentType: try int64(AppleBooksSchema.Book.contentType),
            pageCount: try int64(AppleBooksSchema.Book.pageCount),
            path: try text(AppleBooksSchema.Book.path),
            fileSize: try int64(AppleBooksSchema.Book.fileSize),
            coverURL: try text(AppleBooksSchema.Book.coverURL),
            isFinished: try bool(AppleBooksSchema.Book.isFinished),
            readingProgressRaw: try double(AppleBooksSchema.Book.readingProgress),
            durationRawMilliseconds: try double(AppleBooksSchema.Book.duration),
            creationDate: try date(AppleBooksSchema.Book.creationDate),
            modificationDate: try date(AppleBooksSchema.Book.modificationDate),
            finishedDate: try date(AppleBooksSchema.Book.finishedDate),
            lastOpenDate: try date(AppleBooksSchema.Book.lastOpenDate),
            purchaseDate: try date(AppleBooksSchema.Book.purchaseDate),
            releaseDate: try date(AppleBooksSchema.Book.releaseDate),
            isExplicit: try bool(AppleBooksSchema.Book.isExplicit),
            isLocked: try bool(AppleBooksSchema.Book.isLocked),
            isEphemeral: try bool(AppleBooksSchema.Book.isEphemeral),
            isHidden: try bool(AppleBooksSchema.Book.isHidden),
            isSample: try bool(AppleBooksSchema.Book.isSample),
            isStoreAudiobook: try bool(AppleBooksSchema.Book.isStoreAudiobook),
            rating: try double(AppleBooksSchema.Book.rating)
        )
    }
}

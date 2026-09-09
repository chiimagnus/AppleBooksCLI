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
    case fieldUnavailable(BookSearchField)
}

func validatePagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 {
        throw QueryPaginationError.nonPositiveLimit
    }
    if offset < 0 {
        throw QueryPaginationError.negativeOffset
    }
}

struct BookIdentityMultiplicity: Equatable, Sendable {
    let count: Int
    let uniqueLocalPK: Int64?
}

struct BookIdentityRow: Equatable, Sendable {
    let localPK: Int64
    let assetID: String?
}

struct BookQueries {
    private enum Filter {
        case none
        case localPK(Int64)
        case title(String)
        case genre(String)
        case combinedText(String)
        case pdf
        case assetID(String)
    }

    let connection: SQLiteConnection

    func list(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.none, capability: .bookBase, limit: limit, offset: offset)
    }

    func page(limit: Int? = nil, offset: Int = 0) throws -> Page<Book> {
        let effectiveLimit = try resolvedPageLimit(limit, default: 20, offset: offset)
        let total = try baseTotal()
        let items = try query(.none, capability: .bookBase, limit: effectiveLimit, offset: offset)
        return Page(items: items, total: total, limit: effectiveLimit, offset: offset)
    }

    func summaryPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try summaryPage(searchText: nil, field: nil, limit: limit, cursor: cursor)
    }

    func searchSummaryPage(
        _ text: String,
        field: BookSearchField = .all,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<BookSummary> {
        guard text.isEmpty == false else { throw BookSearchError.emptyQuery }
        return try summaryPage(searchText: text, field: field, limit: limit, cursor: cursor)
    }

    func forEachSummary(
        afterLocalPK: Int64?,
        _ body: (BookSummary) throws -> Bool
    ) throws {
        let schema = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let statement = try canonicalScanStatement(
            projection: summaryProjection(schema: schema, alias: "b"),
            schema: schema,
            afterLocalPK: afterLocalPK
        )
        while try statement.step() {
            if try body(decodeSummary(SQLiteRow(statement: statement), schema: schema)) == false {
                break
            }
        }
    }

    func forEachIdentity(
        afterLocalPK: Int64? = nil,
        _ body: (BookIdentityRow) throws -> Bool
    ) throws {
        let schema = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let projection = ["b.\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"]
            + (schema.contains(AppleBooksSchema.Book.assetID)
                ? ["b.\(AppleBooksSchema.Book.assetID) AS \(AppleBooksSchema.Book.assetID)"]
                : [])
        let statement = try canonicalScanStatement(
            projection: projection,
            schema: schema,
            afterLocalPK: afterLocalPK
        )
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let localPK = try row.int64(AppleBooksSchema.Book.localPK) else {
                throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
            }
            let item = BookIdentityRow(
                localPK: localPK,
                assetID: schema.contains(AppleBooksSchema.Book.assetID)
                    ? try row.text(AppleBooksSchema.Book.assetID)
                    : nil
            )
            if try body(item) == false { break }
        }
    }

    private func canonicalScanStatement(
        projection: [String],
        schema: SchemaAvailability,
        afterLocalPK: Int64?
    ) throws -> SQLiteStatement {
        let selection = SummarySelection(searchText: nil, field: nil, searchColumns: [])
        if let afterLocalPK,
           try summaryCursorRowExists(localPK: afterLocalPK, selection: selection) == false {
            throw CursorPaginationError.staleCursor
        }
        var sql = ""
        if afterLocalPK != nil {
            sql += "WITH cursor_row AS (SELECT \(summaryCursorProjection(schema: schema)) FROM \(AppleBooksTable.books.rawValue) WHERE \(AppleBooksSchema.Book.localPK) = ?) "
        }
        sql += "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue) AS b"
        if afterLocalPK != nil {
            sql += " CROSS JOIN cursor_row AS c WHERE \(summaryKeysetPredicate(schema: schema, bookAlias: "b", cursorAlias: "c"))"
        }
        sql += " ORDER BY \(summaryOrder(schema: schema, alias: "b").joined(separator: ", "))"
        let statement = try connection.prepare(sql)
        if let afterLocalPK { try statement.bind(afterLocalPK, at: 1) }
        return statement
    }

    func identityMultiplicity(assetIDs: [String]) throws -> [String: BookIdentityMultiplicity] {
        guard assetIDs.count <= 100 else { throw AnnotationAggregateQueryError.batchTooLarge }
        let unique = Array(Set(assetIDs))
        guard unique.isEmpty == false else { return [:] }
        _ = try AppleBooksSchema.inspect(.bookAssetLookup, on: connection)
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let statement = try connection.prepare("""
        SELECT \(AppleBooksSchema.Book.assetID) AS assetID,
               COUNT(*) AS count,
               MIN(\(AppleBooksSchema.Book.localPK)) AS minPK
        FROM \(AppleBooksTable.books.rawValue)
        WHERE \(AppleBooksSchema.Book.assetID) COLLATE BINARY IN (\(placeholders))
        GROUP BY \(AppleBooksSchema.Book.assetID) COLLATE BINARY
        """)
        for (offset, assetID) in unique.enumerated() {
            try statement.bind(assetID, at: Int32(offset + 1))
        }
        var result: [String: BookIdentityMultiplicity] = [:]
        result.reserveCapacity(unique.count)
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let assetID = try row.text("assetID"),
                  let rawCount = try row.int64("count"), rawCount > 0,
                  let minPK = try row.int64("minPK") else {
                throw QueryDecodingError.nullRequiredColumn("book identity multiplicity")
            }
            let count = Int(rawCount)
            result[assetID] = BookIdentityMultiplicity(
                count: count,
                uniqueLocalPK: count == 1 ? minPK : nil
            )
        }
        return result
    }

    func totalCount() throws -> Int {
        try baseTotal()
    }

    func pdfBooks() throws -> [Book] {
        try query(.pdf, capability: .bookPDF, limit: nil, offset: 0)
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
        _ = try AppleBooksSchema.inspect(.bookAssetLookup, on: connection)
        let statement = try connection.prepare("""
            SELECT \(AppleBooksSchema.Book.localPK), \(AppleBooksSchema.Book.assetID)
            FROM \(AppleBooksTable.books.rawValue)
            WHERE \(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Book.localPK)
            LIMIT 2
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step() else { return nil }
        let first = try SQLiteRow(statement: statement)
        guard let localPK = try first.int64(AppleBooksSchema.Book.localPK),
              try first.text(AppleBooksSchema.Book.assetID) == assetID else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }
        if try statement.step() {
            throw StableIdentityError.ambiguousBookAssetID
        }
        return try getByLocalPK(localPK)
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
        case .pdf:
            sql += " WHERE \(AppleBooksSchema.Book.contentType) = 3"
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
        case .pdf:
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

    private struct SummarySelection {
        let searchText: String?
        let field: BookSearchField?
        let searchColumns: [String]
    }

    private func summaryPage(
        searchText: String?,
        field: BookSearchField?,
        limit: Int?,
        cursor: String?
    ) throws -> CursorPage<BookSummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let beforeGeneration = try bookCursorGeneration()
        let schema = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let selection = try summarySelection(searchText: searchText, field: field, schema: schema)
        let fingerprint = try summaryFingerprint(selection: selection, schema: schema)
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )

        let cursorPK: Int64?
        if let locator = session.locator {
            guard locator.words.count == 1 else { throw CursorPaginationError.invalidCursor }
            cursorPK = Int64(bitPattern: locator.words[0])
            guard try summaryCursorRowExists(localPK: cursorPK!, selection: selection) else {
                throw CursorPaginationError.staleCursor
            }
        } else {
            cursorPK = nil
        }

        let total = try summaryCount(selection: selection)
        let candidates = try summaryCandidates(
            selection: selection,
            schema: schema,
            cursorPK: cursorPK,
            limit: effectiveLimit + 1
        )
        let afterGeneration = try bookCursorGeneration()
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            total: total,
            session: session,
            afterGeneration: afterGeneration,
            locator: { try .rowID($0.localPK) }
        )
    }

    private func summarySelection(
        searchText: String?,
        field: BookSearchField?,
        schema: SchemaAvailability
    ) throws -> SummarySelection {
        guard let searchText else {
            return SummarySelection(searchText: nil, field: nil, searchColumns: [])
        }
        let resolvedField = field ?? .all
        let columns: [String]
        switch resolvedField {
        case .all:
            columns = [
                AppleBooksSchema.Book.title,
                AppleBooksSchema.Book.author,
                AppleBooksSchema.Book.genre,
            ].filter(schema.contains)
            guard columns.isEmpty == false else { throw BookSearchError.noSearchableColumns }
        case .title:
            guard schema.contains(AppleBooksSchema.Book.title) else {
                throw BookSearchError.fieldUnavailable(.title)
            }
            columns = [AppleBooksSchema.Book.title]
        case .author:
            guard schema.contains(AppleBooksSchema.Book.author) else {
                throw BookSearchError.fieldUnavailable(.author)
            }
            columns = [AppleBooksSchema.Book.author]
        case .genre:
            guard schema.contains(AppleBooksSchema.Book.genre) else {
                throw BookSearchError.fieldUnavailable(.genre)
            }
            columns = [AppleBooksSchema.Book.genre]
        }
        return SummarySelection(searchText: searchText, field: resolvedField, searchColumns: columns)
    }

    private func summaryFingerprint(
        selection: SummarySelection,
        schema: SchemaAvailability
    ) throws -> CursorQueryFingerprint {
        var fields = [
            CursorFingerprintField("order.version", .unsigned(1)),
            CursorFingerprintField("order.title", .bool(schema.contains(AppleBooksSchema.Book.title))),
            CursorFingerprintField("order.assetID", .bool(schema.contains(AppleBooksSchema.Book.assetID))),
        ]
        let kind: String
        if let searchText = selection.searchText, let field = selection.field {
            kind = "books.search"
            fields += [
                CursorFingerprintField("field", .string(field.rawValue)),
                CursorFingerprintField("query", .string(searchText)),
                CursorFingerprintField("searchColumns", .strings(selection.searchColumns)),
            ]
        } else {
            kind = "books.list"
        }
        return try CursorQueryFingerprint.make(kind: kind, fields: fields)
    }

    private func bookCursorGeneration() throws -> CursorGeneration {
        try CursorGeneration.compose([
            CursorGenerationComponent.sqlite(label: "library", databaseURL: connection.databaseURL),
        ])
    }

    private func summaryCount(selection: SummarySelection) throws -> Int {
        var sql = "SELECT COUNT(*) AS count FROM \(AppleBooksTable.books.rawValue) AS b"
        if let predicate = summarySearchPredicate(selection: selection, alias: "b") {
            sql += " WHERE \(predicate)"
        }
        let statement = try connection.prepare(sql)
        try bindSummarySearch(selection: selection, to: statement, startingAt: 1)
        guard try statement.step(),
              let count = try SQLiteRow(statement: statement).int64("count"),
              count >= 0,
              try statement.step() == false else {
            throw QueryDecodingError.nullRequiredColumn("count")
        }
        return Int(count)
    }

    private func summaryCursorRowExists(localPK: Int64, selection: SummarySelection) throws -> Bool {
        var sql = "SELECT 1 AS present FROM \(AppleBooksTable.books.rawValue) AS b WHERE b.\(AppleBooksSchema.Book.localPK) = ?"
        if let predicate = summarySearchPredicate(selection: selection, alias: "b") {
            sql += " AND \(predicate)"
        }
        let statement = try connection.prepare(sql)
        try statement.bind(localPK, at: 1)
        try bindSummarySearch(selection: selection, to: statement, startingAt: 2)
        guard try statement.step() else { return false }
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return true
    }

    private func summaryCandidates(
        selection: SummarySelection,
        schema: SchemaAvailability,
        cursorPK: Int64?,
        limit: Int
    ) throws -> [BookSummary] {
        let projection = summaryProjection(schema: schema, alias: "b")
        var sql = ""
        if cursorPK != nil {
            sql += "WITH cursor_row AS (SELECT \(summaryCursorProjection(schema: schema)) FROM \(AppleBooksTable.books.rawValue) WHERE \(AppleBooksSchema.Book.localPK) = ?) "
        }
        sql += "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue) AS b"
        if cursorPK != nil {
            sql += " CROSS JOIN cursor_row AS c"
        }

        var predicates: [String] = []
        if let search = summarySearchPredicate(selection: selection, alias: "b") {
            predicates.append(search)
        }
        if cursorPK != nil {
            predicates.append(summaryKeysetPredicate(schema: schema, bookAlias: "b", cursorAlias: "c"))
        }
        if predicates.isEmpty == false {
            sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        }
        sql += " ORDER BY " + summaryOrder(schema: schema, alias: "b").joined(separator: ", ")
        sql += " LIMIT ?"

        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        if let cursorPK {
            try statement.bind(cursorPK, at: index)
            index += 1
        }
        index = try bindSummarySearch(selection: selection, to: statement, startingAt: index)
        try statement.bind(Int64(limit), at: index)

        var result: [BookSummary] = []
        result.reserveCapacity(limit)
        while try statement.step() {
            result.append(try decodeSummary(SQLiteRow(statement: statement), schema: schema))
        }
        return result
    }

    private func summaryProjection(schema: SchemaAvailability, alias: String) -> [String] {
        ["\(alias).\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"] + [
            AppleBooksSchema.Book.assetID,
            AppleBooksSchema.Book.title,
            AppleBooksSchema.Book.author,
            AppleBooksSchema.Book.contentType,
        ].filter(schema.contains).map { "\(alias).\($0) AS \($0)" }
    }

    private func summaryCursorProjection(schema: SchemaAvailability) -> String {
        var columns = ["\(AppleBooksSchema.Book.localPK) AS cursorPK"]
        if schema.contains(AppleBooksSchema.Book.title) {
            columns.append("\(AppleBooksSchema.Book.title) AS cursorTitle")
        }
        if schema.contains(AppleBooksSchema.Book.assetID) {
            columns.append("\(AppleBooksSchema.Book.assetID) AS cursorAssetID")
        }
        return columns.joined(separator: ", ")
    }

    private func summaryOrder(schema: SchemaAvailability, alias: String) -> [String] {
        var order: [String] = []
        if schema.contains(AppleBooksSchema.Book.title) {
            order += [
                "\(alias).\(AppleBooksSchema.Book.title) IS NULL",
                "\(alias).\(AppleBooksSchema.Book.title) COLLATE NOCASE ASC",
            ]
        }
        if schema.contains(AppleBooksSchema.Book.assetID) {
            order += [
                "\(alias).\(AppleBooksSchema.Book.assetID) IS NULL",
                "\(alias).\(AppleBooksSchema.Book.assetID) COLLATE BINARY ASC",
            ]
        }
        order.append("\(alias).\(AppleBooksSchema.Book.localPK) ASC")
        return order
    }

    private func summaryKeysetPredicate(
        schema: SchemaAvailability,
        bookAlias: String,
        cursorAlias: String
    ) -> String {
        let bookPK = "\(bookAlias).\(AppleBooksSchema.Book.localPK)"
        let cursorPK = "\(cursorAlias).cursorPK"
        let pkAfter = "\(bookPK) > \(cursorPK)"

        let assetAfter: String
        if schema.contains(AppleBooksSchema.Book.assetID) {
            let bookAsset = "\(bookAlias).\(AppleBooksSchema.Book.assetID)"
            let cursorAsset = "\(cursorAlias).cursorAssetID"
            assetAfter = "((\(cursorAsset) IS NULL AND \(bookAsset) IS NULL AND \(pkAfter)) OR (\(cursorAsset) IS NOT NULL AND (\(bookAsset) IS NULL OR (\(bookAsset) IS NOT NULL AND (\(bookAsset) COLLATE BINARY > \(cursorAsset) COLLATE BINARY OR (\(bookAsset) COLLATE BINARY = \(cursorAsset) COLLATE BINARY AND \(pkAfter)))))))"
        } else {
            assetAfter = pkAfter
        }

        guard schema.contains(AppleBooksSchema.Book.title) else { return assetAfter }
        let bookTitle = "\(bookAlias).\(AppleBooksSchema.Book.title)"
        let cursorTitle = "\(cursorAlias).cursorTitle"
        return "((\(cursorTitle) IS NULL AND \(bookTitle) IS NULL AND (\(assetAfter))) OR (\(cursorTitle) IS NOT NULL AND (\(bookTitle) IS NULL OR (\(bookTitle) IS NOT NULL AND (\(bookTitle) COLLATE NOCASE > \(cursorTitle) COLLATE NOCASE OR (\(bookTitle) COLLATE NOCASE = \(cursorTitle) COLLATE NOCASE AND (\(assetAfter))))))))"
    }

    private func summarySearchPredicate(selection: SummarySelection, alias: String) -> String? {
        guard selection.searchText != nil else { return nil }
        return selection.searchColumns
            .map { "\(alias).\($0) LIKE ? ESCAPE '\\' COLLATE NOCASE" }
            .joined(separator: " OR ")
    }

    @discardableResult
    private func bindSummarySearch(
        selection: SummarySelection,
        to statement: SQLiteStatement,
        startingAt startIndex: Int32
    ) throws -> Int32 {
        guard let searchText = selection.searchText else { return startIndex }
        let pattern = literalContainsPattern(searchText)
        var index = startIndex
        for _ in selection.searchColumns {
            try statement.bind(pattern, at: index)
            index += 1
        }
        return index
    }

    private func decodeSummary(_ row: SQLiteRow, schema: SchemaAvailability) throws -> BookSummary {
        guard let localPK = try row.int64(AppleBooksSchema.Book.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }
        func text(_ column: String) throws -> String? {
            schema.contains(column) ? try row.text(column) : nil
        }
        func int64(_ column: String) throws -> Int64? {
            schema.contains(column) ? try row.int64(column) : nil
        }
        return BookSummary(
            localPK: localPK,
            assetID: try text(AppleBooksSchema.Book.assetID),
            title: try text(AppleBooksSchema.Book.title),
            author: try text(AppleBooksSchema.Book.author),
            contentType: try int64(AppleBooksSchema.Book.contentType)
        )
    }

    private func baseTotal() throws -> Int {
        _ = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let statement = try connection.prepare(
            "SELECT COUNT(*) AS count FROM \(AppleBooksTable.books.rawValue)"
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

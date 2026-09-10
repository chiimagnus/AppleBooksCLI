import Foundation

public enum QueryDecodingError: Error, Equatable, Sendable {
    case nullRequiredColumn(String)
}

public enum BookSearchError: Error, Equatable, Sendable {
    case emptyQuery
    case noSearchableColumns
    case fieldUnavailable(BookSearchField)
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
        case localPK(Int64)
        case assetID(String)
    }

    let connection: SQLiteConnection

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
        var projection = ["b.\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"]
        if schema.contains(AppleBooksSchema.Book.assetID) {
            projection += SQLiteTextProjection.exact(
                "b.\(AppleBooksSchema.Book.assetID)",
                alias: "bookIdentity",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
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
            let assetID: String?
            if schema.contains(AppleBooksSchema.Book.assetID) {
                switch try SQLiteTextProjection.decodeExact(
                    row,
                    alias: "bookIdentity",
                    column: AppleBooksSchema.Book.assetID,
                    maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
                ) {
                case let .value(value) where PublicStableIdentityPolicy.isEligible(value):
                    assetID = value
                case .value, .null, .oversized:
                    assetID = nil
                }
            } else {
                assetID = nil
            }
            let item = BookIdentityRow(localPK: localPK, assetID: assetID)
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

    func forEachPDFResourceTarget(
        _ body: (BookResourceTarget, Int) throws -> Bool
    ) throws {
        _ = try AppleBooksSchema.inspect(.bookPDF, on: connection)
        let schema = try AppleBooksSchema.inspect(.bookContentPathLookup, on: connection)
        var projection = [
            "b.\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)",
            "b.\(AppleBooksSchema.Book.contentType) AS \(AppleBooksSchema.Book.contentType)",
        ]
        let multiplicityCTE: String
        let multiplicityJoin: String
        if schema.contains(AppleBooksSchema.Book.assetID) {
            projection += SQLiteTextProjection.exact(
                "b.\(AppleBooksSchema.Book.assetID)",
                alias: "pdfResourceAssetID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
            projection.append("COALESCE(identity_count.pdfAssetMultiplicity, 0) AS pdfAssetMultiplicity")
            multiplicityCTE = """
            WITH identity_counts AS (
              SELECT \(AppleBooksSchema.Book.assetID) AS assetID,
                     COUNT(*) AS pdfAssetMultiplicity
              FROM \(AppleBooksTable.books.rawValue)
              WHERE typeof(\(AppleBooksSchema.Book.assetID)) = 'text'
              GROUP BY \(AppleBooksSchema.Book.assetID) COLLATE BINARY
            )
            """
            multiplicityJoin = """
            LEFT JOIN identity_counts AS identity_count
              ON identity_count.assetID = b.\(AppleBooksSchema.Book.assetID) COLLATE BINARY
            """
        } else {
            multiplicityCTE = ""
            multiplicityJoin = ""
        }
        projection += SQLiteTextProjection.exact(
            "b.\(AppleBooksSchema.Book.path)",
            alias: "pdfResourcePath",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.resourcePath
        )
        let statement = try connection.prepare("""
        \(multiplicityCTE)
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        \(multiplicityJoin)
        WHERE b.\(AppleBooksSchema.Book.contentType) = 3
        ORDER BY b.\(AppleBooksSchema.Book.localPK) ASC
        """)
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let localPK = try row.int64(AppleBooksSchema.Book.localPK), localPK > 0 else {
                throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
            }
            let assetID: String?
            let multiplicity: Int
            if schema.contains(AppleBooksSchema.Book.assetID) {
                switch try SQLiteTextProjection.decodeExact(
                    row,
                    alias: "pdfResourceAssetID",
                    column: AppleBooksSchema.Book.assetID,
                    maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
                ) {
                case let .value(value) where PublicStableIdentityPolicy.isEligible(value): assetID = value
                case .value, .null, .oversized: assetID = nil
                }
                let rawMultiplicity = try row.int64("pdfAssetMultiplicity") ?? 0
                multiplicity = rawMultiplicity > 0 && rawMultiplicity <= Int64(Int.max) ? Int(rawMultiplicity) : 0
            } else {
                assetID = nil
                multiplicity = 0
            }
            let target = BookResourceTarget(
                localPK: localPK,
                assetID: assetID,
                contentType: try row.int64(AppleBooksSchema.Book.contentType),
                path: try decodeResourcePath(row, alias: "pdfResourcePath")
            )
            if try body(target, multiplicity) == false { break }
        }
    }

    func pdfResourceTarget(localPK: Int64) throws -> BookResourceTarget? {
        _ = try AppleBooksSchema.inspect(.bookPDF, on: connection)
        guard let target = try resourceTarget(localPK: localPK), target.contentType == 3 else { return nil }
        return target
    }

    func getByLocalPK(_ localPK: Int64) throws -> Book? {
        try query(.localPK(localPK), capability: .bookBase).first
    }

    func getByAssetID(_ assetID: String) throws -> [Book] {
        try query(.assetID(assetID), capability: .bookAssetLookup)
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
        try query(.localPK(localPK), capability: .bookCurrentReadingAssetLookup).first
    }

    func getForContent(_ localPK: Int64) throws -> Book? {
        try query(.localPK(localPK), capability: .bookContentPathLookup).first
    }

    func semanticDetail(localPK: Int64) throws -> SemanticBookDetail? {
        let schema = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let projection = semanticDetailProjection(schema: schema, alias: "b")
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        WHERE b.\(AppleBooksSchema.Book.localPK) = ?
        LIMIT 1
        """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        return try decodeSemanticDetail(SQLiteRow(statement: statement), schema: schema)
    }

    func semanticSummaries(assetID: String) throws -> [BookSummary] {
        let schema = try AppleBooksSchema.inspect(.bookAssetLookup, on: connection)
        let projection = summaryProjection(schema: schema, alias: "b")
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        WHERE b.\(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY
        ORDER BY b.\(AppleBooksSchema.Book.localPK)
        """)
        try statement.bind(assetID, at: 1)
        var result: [BookSummary] = []
        while try statement.step() {
            result.append(try decodeSummary(SQLiteRow(statement: statement), schema: schema))
        }
        return result
    }

    func semanticSummary(localPK: Int64) throws -> BookSummary? {
        try semanticSummaries(localPKs: [localPK])[localPK]
    }

    func semanticSummaries(localPKs: [Int64]) throws -> [Int64: BookSummary] {
        guard localPKs.count <= AnnotationSourceClassifier.maximumBatch else {
            throw AnnotationAggregateQueryError.batchTooLarge
        }
        let unique = Array(Set(localPKs))
        guard unique.isEmpty == false else { return [:] }
        let schema = try AppleBooksSchema.inspect(.bookBase, on: connection)
        let projection = summaryProjection(schema: schema, alias: "b")
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        WHERE b.\(AppleBooksSchema.Book.localPK) IN (\(placeholders))
        """)
        for (offset, localPK) in unique.enumerated() {
            try statement.bind(localPK, at: Int32(offset + 1))
        }
        var result: [Int64: BookSummary] = [:]
        result.reserveCapacity(unique.count)
        while try statement.step() {
            let summary = try decodeSummary(SQLiteRow(statement: statement), schema: schema)
            result[summary.localPK] = summary
        }
        return result
    }

    func semanticDetail(assetID: String) throws -> SemanticBookDetail? {
        _ = try AppleBooksSchema.inspect(.bookAssetLookup, on: connection)
        let statement = try connection.prepare("""
        SELECT \(AppleBooksSchema.Book.localPK)
        FROM \(AppleBooksTable.books.rawValue)
        WHERE \(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY
        ORDER BY \(AppleBooksSchema.Book.localPK)
        LIMIT 2
        """)
        try statement.bind(assetID, at: 1)
        guard try statement.step(),
              let localPK = try SQLiteRow(statement: statement).int64(AppleBooksSchema.Book.localPK) else {
            return nil
        }
        if try statement.step() { throw StableIdentityError.ambiguousBookAssetID }
        return try semanticDetail(localPK: localPK)
    }

    func uniqueResourceTarget(assetID: String) throws -> BookResourceTarget? {
        _ = try AppleBooksSchema.inspect(.bookAssetLookup, on: connection)
        let statement = try connection.prepare("""
            SELECT \(AppleBooksSchema.Book.localPK)
            FROM \(AppleBooksTable.books.rawValue)
            WHERE \(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Book.localPK)
            LIMIT 2
            """)
        try statement.bind(assetID, at: 1)
        guard try statement.step(),
              let localPK = try SQLiteRow(statement: statement).int64(AppleBooksSchema.Book.localPK),
              localPK > 0 else {
            return nil
        }
        if try statement.step() { throw StableIdentityError.ambiguousBookAssetID }
        return try resourceTarget(localPK: localPK)
    }

    func contentMetadataFallback(localPK: Int64) throws -> BookContentMetadataFallback? {
        let schema = try AppleBooksSchema.inspect(.bookContentPathLookup, on: connection)
        var projection: [String] = []
        for (column, alias, budget) in [
            (AppleBooksSchema.Book.title, "contentMetadataTitle", SQLiteSemanticTextBudget.metadata),
            (AppleBooksSchema.Book.author, "contentMetadataAuthor", SQLiteSemanticTextBudget.metadata),
            (AppleBooksSchema.Book.language, "contentMetadataLanguage", SQLiteSemanticTextBudget.shortMetadata),
        ] where schema.contains(column) {
            projection += SQLiteTextProjection.bounded(
                "b.\(column)",
                alias: alias,
                maximumUTF8Bytes: budget
            )
        }
        if schema.contains(AppleBooksSchema.Book.releaseDate) {
            projection.append("b.\(AppleBooksSchema.Book.releaseDate) AS \(AppleBooksSchema.Book.releaseDate)")
        }
        if projection.isEmpty {
            return BookContentMetadataFallback(
                title: nil,
                author: nil,
                language: nil,
                releaseDate: nil,
                byteTruncatedFields: []
            )
        }
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        WHERE b.\(AppleBooksSchema.Book.localPK) = ?
        LIMIT 1
        """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        func bounded(_ column: String, alias: String, budget: Int) throws -> BoundedSQLiteText {
            guard schema.contains(column) else {
                return BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
            }
            return try SQLiteTextProjection.decodeBounded(
                row,
                alias: alias,
                column: column,
                maximumUTF8Bytes: budget
            )
        }
        let title = try bounded(AppleBooksSchema.Book.title, alias: "contentMetadataTitle", budget: SQLiteSemanticTextBudget.metadata)
        let author = try bounded(AppleBooksSchema.Book.author, alias: "contentMetadataAuthor", budget: SQLiteSemanticTextBudget.metadata)
        let language = try bounded(AppleBooksSchema.Book.language, alias: "contentMetadataLanguage", budget: SQLiteSemanticTextBudget.shortMetadata)
        var truncated: [String] = []
        if title.wasByteTruncated { truncated.append("title") }
        if author.wasByteTruncated { truncated.append("author") }
        if language.wasByteTruncated { truncated.append("language") }
        return BookContentMetadataFallback(
            title: title.value,
            author: normalizedAppleBooksAuthor(author.value),
            language: language.value,
            releaseDate: schema.contains(AppleBooksSchema.Book.releaseDate)
                ? CoreDataTime.date(from: try row.double(AppleBooksSchema.Book.releaseDate))
                : nil,
            byteTruncatedFields: truncated
        )
    }

    func resourceTarget(localPK: Int64) throws -> BookResourceTarget? {
        let schema = try AppleBooksSchema.inspect(.bookContentPathLookup, on: connection)
        var projection = ["b.\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"]
        if schema.contains(AppleBooksSchema.Book.assetID) {
            projection += SQLiteTextProjection.exact(
                "b.\(AppleBooksSchema.Book.assetID)",
                alias: "resourceAssetID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        if schema.contains(AppleBooksSchema.Book.contentType) {
            projection.append("b.\(AppleBooksSchema.Book.contentType) AS \(AppleBooksSchema.Book.contentType)")
        }
        projection += SQLiteTextProjection.exact(
            "b.\(AppleBooksSchema.Book.path)",
            alias: "resourcePath",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.resourcePath
        )
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue) AS b
        WHERE b.\(AppleBooksSchema.Book.localPK) = ?
        LIMIT 1
        """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        guard let decodedPK = try row.int64(AppleBooksSchema.Book.localPK), decodedPK > 0 else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }
        let assetID: String?
        if schema.contains(AppleBooksSchema.Book.assetID) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "resourceAssetID",
                column: AppleBooksSchema.Book.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value): assetID = value
            case .value, .null, .oversized: assetID = nil
            }
        } else {
            assetID = nil
        }
        return BookResourceTarget(
            localPK: decodedPK,
            assetID: assetID,
            contentType: schema.contains(AppleBooksSchema.Book.contentType)
                ? try row.int64(AppleBooksSchema.Book.contentType)
                : nil,
            path: try decodeResourcePath(row, alias: "resourcePath")
        )
    }

    private func decodeResourcePath(_ row: SQLiteRow, alias: String) throws -> String? {
        do {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: alias,
                column: AppleBooksSchema.Book.path,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.resourcePath
            ) {
            case let .value(value) where value.utf8.contains(0) == false: return value
            case .value, .null, .oversized: return nil
            }
        } catch is SQLiteRowError {
            return nil
        }
    }

    func annotationAssetID(localPK: Int64) throws -> String? {
        let schema = try AppleBooksSchema.inspect(.bookCurrentReadingAssetLookup, on: connection)
        guard schema.contains(AppleBooksSchema.Book.assetID) else { return nil }
        let projection = SQLiteTextProjection.exact(
            AppleBooksSchema.Book.assetID,
            alias: "annotationLookupAssetID",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.sourceIdentity
        )
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue)
        WHERE \(AppleBooksSchema.Book.localPK) = ?
        LIMIT 1
        """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        switch try SQLiteTextProjection.decodeExact(
            SQLiteRow(statement: statement),
            alias: "annotationLookupAssetID",
            column: AppleBooksSchema.Book.assetID,
            maximumUTF8Bytes: SQLiteSemanticTextBudget.sourceIdentity
        ) {
        case let .value(value): return value
        case .null, .oversized: return nil
        }
    }

    func semanticAssetID(localPK: Int64) throws -> String? {
        let schema = try AppleBooksSchema.inspect(.bookCurrentReadingAssetLookup, on: connection)
        guard schema.contains(AppleBooksSchema.Book.assetID) else { return nil }
        let projection = SQLiteTextProjection.exact(
            AppleBooksSchema.Book.assetID,
            alias: "readingAssetID",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
        )
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.books.rawValue)
        WHERE \(AppleBooksSchema.Book.localPK) = ?
        LIMIT 1
        """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        switch try SQLiteTextProjection.decodeExact(
            SQLiteRow(statement: statement),
            alias: "readingAssetID",
            column: AppleBooksSchema.Book.assetID,
            maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
        ) {
        case let .value(value) where PublicStableIdentityPolicy.isEligible(value): return value
        case .value, .null, .oversized: return nil
        }
    }

    private func query(_ filter: Filter, capability: SchemaCapability) throws -> [Book] {
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let projection = [AppleBooksSchema.Book.localPK] + AppleBooksSchema.Book.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue)"
        switch filter {
        case .localPK:
            sql += " WHERE \(AppleBooksSchema.Book.localPK) = ?"
        case .assetID:
            sql += " WHERE \(AppleBooksSchema.Book.assetID) = ? COLLATE BINARY"
        }
        sql += " ORDER BY \(AppleBooksSchema.Book.localPK)"

        let statement = try connection.prepare(sql)
        switch filter {
        case let .localPK(value):
            try statement.bind(value, at: 1)
        case let .assetID(value):
            try statement.bind(value, at: 1)
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

    func summaryProjection(schema: SchemaAvailability, alias: String) -> [String] {
        var projection = ["\(alias).\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"]
        if schema.contains(AppleBooksSchema.Book.assetID) {
            projection += SQLiteTextProjection.exact(
                "\(alias).\(AppleBooksSchema.Book.assetID)",
                alias: "summaryAssetID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        if schema.contains(AppleBooksSchema.Book.title) {
            projection += SQLiteTextProjection.bounded(
                "\(alias).\(AppleBooksSchema.Book.title)",
                alias: "summaryTitle",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        }
        if schema.contains(AppleBooksSchema.Book.author) {
            projection += SQLiteTextProjection.bounded(
                "\(alias).\(AppleBooksSchema.Book.author)",
                alias: "summaryAuthor",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        }
        if schema.contains(AppleBooksSchema.Book.contentType) {
            projection.append("\(alias).\(AppleBooksSchema.Book.contentType) AS \(AppleBooksSchema.Book.contentType)")
        }
        return projection
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

    func decodeSummary(_ row: SQLiteRow, schema: SchemaAvailability) throws -> BookSummary {
        guard let localPK = try row.int64(AppleBooksSchema.Book.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }
        let assetID: String?
        if schema.contains(AppleBooksSchema.Book.assetID) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "summaryAssetID",
                column: AppleBooksSchema.Book.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value): assetID = value
            case .value, .null, .oversized: assetID = nil
            }
        } else {
            assetID = nil
        }
        let title = try boundedSummaryText(
            row,
            schema: schema,
            column: AppleBooksSchema.Book.title,
            alias: "summaryTitle"
        )
        let author = try boundedSummaryText(
            row,
            schema: schema,
            column: AppleBooksSchema.Book.author,
            alias: "summaryAuthor"
        )
        var truncated: [String] = []
        if title.wasByteTruncated { truncated.append("title") }
        if author.wasByteTruncated { truncated.append("author") }
        return BookSummary(
            localPK: localPK,
            assetID: assetID,
            title: title.value,
            author: author.value,
            contentType: schema.contains(AppleBooksSchema.Book.contentType)
                ? try row.int64(AppleBooksSchema.Book.contentType)
                : nil,
            byteTruncatedFields: truncated
        )
    }

    private func boundedSummaryText(
        _ row: SQLiteRow,
        schema: SchemaAvailability,
        column: String,
        alias: String
    ) throws -> BoundedSQLiteText {
        guard schema.contains(column) else {
            return BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
        }
        return try SQLiteTextProjection.decodeBounded(
            row,
            alias: alias,
            column: column,
            maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
        )
    }

    private func semanticDetailProjection(schema: SchemaAvailability, alias: String) -> [String] {
        var projection = ["\(alias).\(AppleBooksSchema.Book.localPK) AS \(AppleBooksSchema.Book.localPK)"]
        if schema.contains(AppleBooksSchema.Book.assetID) {
            projection += SQLiteTextProjection.exact(
                "\(alias).\(AppleBooksSchema.Book.assetID)",
                alias: "detailAssetID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        for (column, fieldAlias, budget) in [
            (AppleBooksSchema.Book.title, "detailTitle", SQLiteSemanticTextBudget.metadata),
            (AppleBooksSchema.Book.author, "detailAuthor", SQLiteSemanticTextBudget.metadata),
            (AppleBooksSchema.Book.description, "detailDescription", SQLiteSemanticTextBudget.detail),
            (AppleBooksSchema.Book.genre, "detailGenre", SQLiteSemanticTextBudget.metadata),
            (AppleBooksSchema.Book.language, "detailLanguage", SQLiteSemanticTextBudget.shortMetadata),
        ] where schema.contains(column) {
            projection += SQLiteTextProjection.bounded(
                "\(alias).\(column)",
                alias: fieldAlias,
                maximumUTF8Bytes: budget
            )
        }
        for column in [
            AppleBooksSchema.Book.year,
            AppleBooksSchema.Book.pageCount,
            AppleBooksSchema.Book.contentType,
            AppleBooksSchema.Book.readingProgress,
            AppleBooksSchema.Book.isFinished,
            AppleBooksSchema.Book.finishedDate,
            AppleBooksSchema.Book.lastOpenDate,
            AppleBooksSchema.Book.releaseDate,
        ] where schema.contains(column) {
            projection.append("\(alias).\(column) AS \(column)")
        }
        return projection
    }

    private func decodeSemanticDetail(_ row: SQLiteRow, schema: SchemaAvailability) throws -> SemanticBookDetail {
        guard let localPK = try row.int64(AppleBooksSchema.Book.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Book.localPK)
        }
        let assetID: String?
        if schema.contains(AppleBooksSchema.Book.assetID) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "detailAssetID",
                column: AppleBooksSchema.Book.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value): assetID = value
            case .value, .null, .oversized: assetID = nil
            }
        } else {
            assetID = nil
        }
        func bounded(_ column: String, alias: String, budget: Int) throws -> BoundedSQLiteText {
            guard schema.contains(column) else {
                return BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
            }
            return try SQLiteTextProjection.decodeBounded(
                row,
                alias: alias,
                column: column,
                maximumUTF8Bytes: budget
            )
        }
        let title = try bounded(AppleBooksSchema.Book.title, alias: "detailTitle", budget: SQLiteSemanticTextBudget.metadata)
        let author = try bounded(AppleBooksSchema.Book.author, alias: "detailAuthor", budget: SQLiteSemanticTextBudget.metadata)
        let description = try bounded(AppleBooksSchema.Book.description, alias: "detailDescription", budget: SQLiteSemanticTextBudget.detail)
        let genre = try bounded(AppleBooksSchema.Book.genre, alias: "detailGenre", budget: SQLiteSemanticTextBudget.metadata)
        let language = try bounded(AppleBooksSchema.Book.language, alias: "detailLanguage", budget: SQLiteSemanticTextBudget.shortMetadata)
        var truncated: [String] = []
        for (field, value) in [
            ("title", title), ("author", author), ("description", description),
            ("genre", genre), ("language", language),
        ] where value.wasByteTruncated {
            truncated.append(field)
        }
        func int64(_ column: String) throws -> Int64? {
            schema.contains(column) ? try row.int64(column) : nil
        }
        func double(_ column: String) throws -> Double? {
            schema.contains(column) ? try row.double(column) : nil
        }
        return SemanticBookDetail(
            localPK: localPK,
            assetID: assetID,
            title: title.value,
            author: normalizedAppleBooksAuthor(author.value),
            description: description.value,
            genre: genre.value,
            language: language.value,
            year: try int64(AppleBooksSchema.Book.year),
            pageCount: try int64(AppleBooksSchema.Book.pageCount),
            contentType: try int64(AppleBooksSchema.Book.contentType),
            readingProgressRaw: SemanticSQLiteReal.finite(try double(AppleBooksSchema.Book.readingProgress)),
            isFinished: try int64(AppleBooksSchema.Book.isFinished).map { $0 != 0 },
            finishedDate: CoreDataTime.date(from: try double(AppleBooksSchema.Book.finishedDate)),
            lastOpenDate: CoreDataTime.date(from: try double(AppleBooksSchema.Book.lastOpenDate)),
            releaseDate: CoreDataTime.date(from: try double(AppleBooksSchema.Book.releaseDate)),
            byteTruncatedFields: truncated
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

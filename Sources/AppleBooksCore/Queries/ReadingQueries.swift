enum ReadingQueryConfigurationError: Error, Equatable, Sendable {
    case missingAnnotationConnection
}

struct ReadingPartitionCounts: Equatable, Sendable {
    let finished: Int
    let inProgress: Int
    let unstarted: Int
}

struct ReadingQueries {
    private enum Kind: Equatable {
        case finished
        case inProgress
        case unstarted
        case recentlyRead

        var cursorKind: String {
            switch self {
            case .finished: "reading.finished"
            case .inProgress: "reading.in-progress"
            case .unstarted: "reading.unstarted"
            case .recentlyRead: "reading.recent"
            }
        }
    }

    let connection: SQLiteConnection
    let annotationConnection: SQLiteConnection?

    init(connection: SQLiteConnection, annotationConnection: SQLiteConnection? = nil) {
        self.connection = connection
        self.annotationConnection = annotationConnection
    }

    func finished(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.finished, capability: .readingFinished, limit: limit, offset: offset)
    }

    func inProgress(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.inProgress, capability: .readingInProgress, limit: limit, offset: offset)
    }

    func unstarted(limit: Int? = nil, offset: Int = 0) throws -> [Book] {
        try query(.unstarted, capability: .readingUnstarted, limit: limit, offset: offset)
    }

    func recentlyRead(limit: Int = 10, offset: Int = 0) throws -> [Book] {
        try query(.recentlyRead, capability: .readingRecentlyRead, limit: limit, offset: offset)
    }

    func semanticFinished(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try semanticQuery(.finished, capability: .readingFinished, limit: limit, offset: offset)
    }

    func semanticInProgress(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try semanticQuery(.inProgress, capability: .readingInProgress, limit: limit, offset: offset)
    }

    func semanticUnstarted(limit: Int? = nil, offset: Int = 0) throws -> [BookSummary] {
        try semanticQuery(.unstarted, capability: .readingUnstarted, limit: limit, offset: offset)
    }

    func semanticRecentlyRead(limit: Int = 10, offset: Int = 0) throws -> [BookSummary] {
        try semanticQuery(.recentlyRead, capability: .readingRecentlyRead, limit: limit, offset: offset)
    }

    func semanticFinishedPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try semanticPage(.finished, capability: .readingFinished, limit: limit, cursor: cursor)
    }

    func semanticInProgressPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try semanticPage(.inProgress, capability: .readingInProgress, limit: limit, cursor: cursor)
    }

    func semanticUnstartedPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try semanticPage(.unstarted, capability: .readingUnstarted, limit: limit, cursor: cursor)
    }

    func semanticRecentlyReadPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<BookSummary> {
        try semanticPage(.recentlyRead, capability: .readingRecentlyRead, limit: limit, cursor: cursor)
    }

    func partitionCounts() throws -> ReadingPartitionCounts {
        _ = try AppleBooksSchema.inspect(.readingInProgress, on: connection)
        let finished = AppleBooksSchema.Book.isFinished
        let progress = SemanticSQLiteReal.finiteSQL(AppleBooksSchema.Book.readingProgress)
        let statement = try connection.prepare("""
        SELECT
          SUM(CASE WHEN COALESCE(\(finished), 0) != 0 THEN 1 ELSE 0 END) AS finishedCount,
          SUM(CASE WHEN COALESCE(\(finished), 0) = 0 AND \(progress) > 0 THEN 1 ELSE 0 END) AS inProgressCount,
          SUM(CASE WHEN COALESCE(\(finished), 0) = 0 AND (\(progress) IS NULL OR \(progress) <= 0) THEN 1 ELSE 0 END) AS unstartedCount
        FROM \(AppleBooksTable.books.rawValue)
        """)
        guard try statement.step() else {
            throw QueryDecodingError.nullRequiredColumn("reading partition counts")
        }
        let row = try SQLiteRow(statement: statement)
        let finishedCount = try row.int64("finishedCount") ?? 0
        let inProgressCount = try row.int64("inProgressCount") ?? 0
        let unstartedCount = try row.int64("unstartedCount") ?? 0
        guard finishedCount >= 0, inProgressCount >= 0, unstartedCount >= 0,
              try statement.step() == false else {
            throw QueryDecodingError.nullRequiredColumn("reading partition counts")
        }
        return ReadingPartitionCounts(
            finished: Int(finishedCount),
            inProgress: Int(inProgressCount),
            unstarted: Int(unstartedCount)
        )
    }

    func semanticCurrentLocation(rawAssetID: String) throws -> Location? {
        guard let annotationConnection else {
            throw ReadingQueryConfigurationError.missingAnnotationConnection
        }
        let schema = try AppleBooksSchema.inspect(.currentPosition, on: annotationConnection)
        var projection = [AppleBooksSchema.Annotation.localPK]
        if schema.contains(AppleBooksSchema.Annotation.location) {
            projection += SQLiteTextProjection.exact(
                AppleBooksSchema.Annotation.location,
                alias: "currentReadingLocation",
                maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
            )
        }
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue)"
        sql += " WHERE \(AppleBooksSchema.Annotation.isDeleted) = 0"
        sql += " AND \(AppleBooksSchema.Annotation.type) = 3"
        sql += " AND \(AppleBooksSchema.Annotation.assetID) = ? COLLATE BINARY"
        if schema.contains(AppleBooksSchema.Annotation.modificationDate) {
            let modified = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
            sql += " ORDER BY \(modified) IS NULL, \(modified) DESC, \(AppleBooksSchema.Annotation.localPK) DESC"
        } else {
            sql += " ORDER BY \(AppleBooksSchema.Annotation.localPK) DESC"
        }
        sql += " LIMIT 1"

        let statement = try annotationConnection.prepare(sql)
        try statement.bind(rawAssetID, at: 1)
        guard try statement.step(), schema.contains(AppleBooksSchema.Annotation.location) else { return nil }
        switch try SQLiteTextProjection.decodeExact(
            SQLiteRow(statement: statement),
            alias: "currentReadingLocation",
            column: AppleBooksSchema.Annotation.location,
            maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
        ) {
        case let .value(rawCFI): return Location(rawCFI: rawCFI)
        case .null, .oversized: return nil
        }
    }

    func currentPosition(rawAssetID: String) throws -> Annotation? {
        guard let annotationConnection else {
            throw ReadingQueryConfigurationError.missingAnnotationConnection
        }
        let schema = try AppleBooksSchema.inspect(.currentPosition, on: annotationConnection)
        let projection = [AppleBooksSchema.Annotation.localPK]
            + AppleBooksSchema.Annotation.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue)"
        sql += " WHERE \(AppleBooksSchema.Annotation.isDeleted) = 0"
        sql += " AND \(AppleBooksSchema.Annotation.type) = 3"
        sql += " AND \(AppleBooksSchema.Annotation.assetID) = ?"
        if schema.contains(AppleBooksSchema.Annotation.modificationDate) {
            let modified = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
            sql += " ORDER BY \(modified) IS NULL,"
            sql += " \(modified) DESC,"
            sql += " \(AppleBooksSchema.Annotation.localPK) DESC"
        } else {
            sql += " ORDER BY \(AppleBooksSchema.Annotation.localPK) DESC"
        }
        sql += " LIMIT 1"

        let statement = try annotationConnection.prepare(sql)
        try statement.bind(rawAssetID, at: 1)
        guard try statement.step() else { return nil }
        return try AnnotationQueries.decode(SQLiteRow(statement: statement), schema: schema)
    }

    private func semanticPage(
        _ kind: Kind,
        capability: SchemaCapability,
        limit: Int?,
        cursor: String?
    ) throws -> CursorPage<BookSummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let beforeGeneration = try readingCursorGeneration()
        let fingerprint = try CursorQueryFingerprint.make(
            kind: kind.cursorKind,
            fields: [
                CursorFingerprintField("order.version", .unsigned(1)),
                CursorFingerprintField("order.date", .bool(sortDateSQL(kind, schema: schema, alias: "b") != nil)),
            ]
        )
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )

        let cursorPK: Int64?
        if let locator = session.locator {
            guard locator.words.count == 1 else { throw CursorPaginationError.invalidCursor }
            cursorPK = Int64(bitPattern: locator.words[0])
            guard try semanticCursorRowExists(kind, localPK: cursorPK!, schema: schema) else {
                throw CursorPaginationError.staleCursor
            }
        } else {
            cursorPK = nil
        }

        let candidates = try semanticCandidates(
            kind,
            schema: schema,
            cursorPK: cursorPK,
            limit: effectiveLimit + 1
        )
        let afterGeneration = try readingCursorGeneration()
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            session: session,
            afterGeneration: afterGeneration,
            locator: { try .rowID($0.localPK) }
        )
    }

    private func semanticQuery(
        _ kind: Kind,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [BookSummary] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let decoder = BookQueries(connection: connection)
        let projection = decoder.summaryProjection(schema: schema, alias: "b")
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue) AS b"
        appendSelectionAndOrder(kind, schema: schema, to: &sql)
        if limit != nil {
            sql += " LIMIT ? OFFSET ?"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
        }
        let statement = try connection.prepare(sql)
        if let limit {
            try statement.bind(Int64(limit), at: 1)
            try statement.bind(Int64(offset), at: 2)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: 1)
        }
        var books: [BookSummary] = []
        while try statement.step() {
            books.append(try decoder.decodeSummary(SQLiteRow(statement: statement), schema: schema))
        }
        return books
    }

    private func query(
        _ kind: Kind,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [Book] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let projection = [AppleBooksSchema.Book.localPK]
            + AppleBooksSchema.Book.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue)"
        appendSelectionAndOrder(kind, schema: schema, to: &sql)

        if limit != nil {
            sql += " LIMIT ? OFFSET ?"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
        }

        let statement = try connection.prepare(sql)
        if let limit {
            try statement.bind(Int64(limit), at: 1)
            try statement.bind(Int64(offset), at: 2)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: 1)
        }

        let decoder = BookQueries(connection: connection)
        var books: [Book] = []
        while try statement.step() {
            books.append(try decoder.decode(SQLiteRow(statement: statement), schema: schema))
        }
        return books
    }

    private func semanticCandidates(
        _ kind: Kind,
        schema: SchemaAvailability,
        cursorPK: Int64?,
        limit: Int
    ) throws -> [BookSummary] {
        let decoder = BookQueries(connection: connection)
        let projection = decoder.summaryProjection(schema: schema, alias: "b")
        var sql = ""
        if cursorPK != nil {
            sql += "WITH cursor_row AS (SELECT \(cursorProjection(kind, schema: schema)) FROM \(AppleBooksTable.books.rawValue) WHERE \(AppleBooksSchema.Book.localPK) = ?) "
        }
        sql += "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.books.rawValue) AS b"
        if cursorPK != nil {
            sql += " CROSS JOIN cursor_row AS c"
        }
        var predicates = [selectionPredicate(kind, alias: "b")]
        if cursorPK != nil {
            predicates.append(keysetPredicate(kind, schema: schema, bookAlias: "b", cursorAlias: "c"))
        }
        sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        sql += " ORDER BY \(order(kind, schema: schema, alias: "b").joined(separator: ", "))"
        sql += " LIMIT ?"

        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        if let cursorPK {
            try statement.bind(cursorPK, at: index)
            index += 1
        }
        try statement.bind(Int64(limit), at: index)

        var result: [BookSummary] = []
        result.reserveCapacity(limit)
        while try statement.step() {
            result.append(try decoder.decodeSummary(SQLiteRow(statement: statement), schema: schema))
        }
        return result
    }

    private func semanticCursorRowExists(
        _ kind: Kind,
        localPK: Int64,
        schema: SchemaAvailability
    ) throws -> Bool {
        let statement = try connection.prepare("""
            SELECT 1 AS present
            FROM \(AppleBooksTable.books.rawValue) AS b
            WHERE b.\(AppleBooksSchema.Book.localPK) = ?
              AND (\(selectionPredicate(kind, alias: "b")))
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return false }
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return true
    }

    private func readingCursorGeneration() throws -> CursorGeneration {
        try CursorGeneration.compose([
            .sqlite(label: "library", databaseURL: connection.databaseURL),
        ])
    }

    private func selectionPredicate(_ kind: Kind, alias: String) -> String {
        let prefix = "\(alias)."
        let finished = "\(prefix)\(AppleBooksSchema.Book.isFinished)"
        let progress = SemanticSQLiteReal.finiteSQL("\(prefix)\(AppleBooksSchema.Book.readingProgress)")
        let lastOpen = SemanticSQLiteReal.dateSQL("\(prefix)\(AppleBooksSchema.Book.lastOpenDate)")
        switch kind {
        case .finished:
            return "COALESCE(\(finished), 0) != 0"
        case .inProgress:
            return "COALESCE(\(finished), 0) = 0 AND \(progress) > 0"
        case .unstarted:
            return "COALESCE(\(finished), 0) = 0 AND (\(progress) IS NULL OR \(progress) <= 0)"
        case .recentlyRead:
            return "\(lastOpen) IS NOT NULL"
        }
    }

    private func sortDateSQL(_ kind: Kind, schema: SchemaAvailability, alias: String) -> String? {
        switch kind {
        case .finished:
            guard schema.contains(AppleBooksSchema.Book.finishedDate) else { return nil }
            return SemanticSQLiteReal.dateSQL("\(alias).\(AppleBooksSchema.Book.finishedDate)")
        case .inProgress, .unstarted:
            guard schema.contains(AppleBooksSchema.Book.lastOpenDate) else { return nil }
            return SemanticSQLiteReal.dateSQL("\(alias).\(AppleBooksSchema.Book.lastOpenDate)")
        case .recentlyRead:
            return SemanticSQLiteReal.dateSQL("\(alias).\(AppleBooksSchema.Book.lastOpenDate)")
        }
    }

    private func order(_ kind: Kind, schema: SchemaAvailability, alias: String) -> [String] {
        var result: [String] = []
        if let date = sortDateSQL(kind, schema: schema, alias: alias) {
            if kind != .recentlyRead {
                result.append("\(date) IS NULL")
            }
            result.append("\(date) DESC")
        }
        result.append("\(alias).\(AppleBooksSchema.Book.localPK) DESC")
        return result
    }

    private func cursorProjection(_ kind: Kind, schema: SchemaAvailability) -> String {
        var columns = ["\(AppleBooksSchema.Book.localPK) AS cursorPK"]
        if let date = sortDateSQL(kind, schema: schema, alias: AppleBooksTable.books.rawValue) {
            columns.append("\(date) AS cursorDate")
        }
        return columns.joined(separator: ", ")
    }

    private func keysetPredicate(
        _ kind: Kind,
        schema: SchemaAvailability,
        bookAlias: String,
        cursorAlias: String
    ) -> String {
        let bookPK = "\(bookAlias).\(AppleBooksSchema.Book.localPK)"
        let cursorPK = "\(cursorAlias).cursorPK"
        let pkAfter = "\(bookPK) < \(cursorPK)"
        guard let bookDate = sortDateSQL(kind, schema: schema, alias: bookAlias) else {
            return pkAfter
        }
        let cursorDate = "\(cursorAlias).cursorDate"
        if kind == .recentlyRead {
            return "(\(bookDate) < \(cursorDate) OR (\(bookDate) = \(cursorDate) AND \(pkAfter)))"
        }
        return "((\(cursorDate) IS NULL AND \(bookDate) IS NULL AND \(pkAfter)) OR (\(cursorDate) IS NOT NULL AND (\(bookDate) IS NULL OR (\(bookDate) IS NOT NULL AND (\(bookDate) < \(cursorDate) OR (\(bookDate) = \(cursorDate) AND \(pkAfter)))))))"
    }

    private func appendSelectionAndOrder(
        _ kind: Kind,
        schema: SchemaAvailability,
        to sql: inout String
    ) {
        sql += " WHERE \(selectionPredicate(kind, alias: AppleBooksTable.books.rawValue))"
        sql += " ORDER BY \(order(kind, schema: schema, alias: AppleBooksTable.books.rawValue).joined(separator: ", "))"
    }
}

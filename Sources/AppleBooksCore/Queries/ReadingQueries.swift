enum ReadingQueryConfigurationError: Error, Equatable, Sendable {
    case missingAnnotationConnection
}

struct ReadingQueries {
    private enum Kind {
        case finished
        case inProgress
        case unstarted
        case recentlyRead
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
            sql += " ORDER BY \(AppleBooksSchema.Annotation.modificationDate) IS NULL,"
            sql += " \(AppleBooksSchema.Annotation.modificationDate) DESC,"
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

        switch kind {
        case .finished:
            sql += " WHERE COALESCE(\(AppleBooksSchema.Book.isFinished), 0) != 0"
        case .inProgress:
            sql += " WHERE COALESCE(\(AppleBooksSchema.Book.isFinished), 0) = 0"
            sql += " AND COALESCE(\(AppleBooksSchema.Book.readingProgress), 0) > 0"
        case .unstarted:
            sql += " WHERE COALESCE(\(AppleBooksSchema.Book.isFinished), 0) = 0"
            sql += " AND (\(AppleBooksSchema.Book.readingProgress) IS NULL OR \(AppleBooksSchema.Book.readingProgress) <= 0)"
        case .recentlyRead:
            sql += " WHERE \(AppleBooksSchema.Book.lastOpenDate) IS NOT NULL"
        }

        var order: [String] = []
        switch kind {
        case .finished:
            if schema.contains(AppleBooksSchema.Book.finishedDate) {
                order += [
                    "\(AppleBooksSchema.Book.finishedDate) IS NULL",
                    "\(AppleBooksSchema.Book.finishedDate) DESC",
                ]
            }
        case .inProgress, .unstarted:
            if schema.contains(AppleBooksSchema.Book.lastOpenDate) {
                order += [
                    "\(AppleBooksSchema.Book.lastOpenDate) IS NULL",
                    "\(AppleBooksSchema.Book.lastOpenDate) DESC",
                ]
            }
        case .recentlyRead:
            order.append("\(AppleBooksSchema.Book.lastOpenDate) DESC")
        }
        order.append("\(AppleBooksSchema.Book.localPK) DESC")
        sql += " ORDER BY \(order.joined(separator: ", "))"

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
}

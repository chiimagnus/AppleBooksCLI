import Foundation

struct CollectionQueries {
    private enum Filter {
        case none
        case localPK(Int64)
        case collectionID(String)
        case title(String)
    }

    let connection: SQLiteConnection

    func list(limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try query(.none, capability: .collectionBase, limit: limit, offset: offset)
    }

    func getByLocalPK(_ localPK: Int64) throws -> Collection? {
        try query(.localPK(localPK), capability: .collectionBase, limit: 1, offset: 0).first
    }

    func searchTitle(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [Collection] {
        try query(.title(text), capability: .collectionTitleSearch, limit: limit, offset: offset)
    }

    func semanticList(limit: Int? = nil, offset: Int = 0) throws -> [SemanticCollection] {
        try semanticQuery(.none, capability: .collectionBase, limit: limit, offset: offset)
    }

    func semanticGetByLocalPK(_ localPK: Int64) throws -> SemanticCollection? {
        try semanticQuery(.localPK(localPK), capability: .collectionBase, limit: 1, offset: 0).first
    }

    func semanticSearchTitle(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [SemanticCollection] {
        try semanticQuery(.title(text), capability: .collectionTitleSearch, limit: limit, offset: offset)
    }

    func semanticGetUniqueByCollectionID(_ collectionID: String) throws -> SemanticCollection? {
        _ = try AppleBooksSchema.inspect(.collectionIDLookup, on: connection)
        let statement = try connection.prepare("""
            SELECT \(AppleBooksSchema.Collection.localPK)
            FROM \(AppleBooksTable.collections.rawValue)
            WHERE \(AppleBooksSchema.Collection.isDeleted) = 0
              AND \(AppleBooksSchema.Collection.collectionID) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Collection.localPK)
            LIMIT 2
            """)
        try statement.bind(collectionID, at: 1)
        guard try statement.step(),
              let localPK = try SQLiteRow(statement: statement).int64(AppleBooksSchema.Collection.localPK) else {
            return nil
        }
        if try statement.step() { throw StableIdentityError.ambiguousCollectionID }
        return try semanticGetByLocalPK(localPK)
    }

    func getUniqueByCollectionID(_ collectionID: String) throws -> Collection? {
        _ = try AppleBooksSchema.inspect(.collectionIDLookup, on: connection)
        let statement = try connection.prepare("""
            SELECT \(AppleBooksSchema.Collection.localPK), \(AppleBooksSchema.Collection.collectionID)
            FROM \(AppleBooksTable.collections.rawValue)
            WHERE \(AppleBooksSchema.Collection.isDeleted) = 0
              AND \(AppleBooksSchema.Collection.collectionID) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Collection.localPK)
            LIMIT 2
            """)
        try statement.bind(collectionID, at: 1)
        guard try statement.step() else { return nil }
        let first = try SQLiteRow(statement: statement)
        guard let localPK = try first.int64(AppleBooksSchema.Collection.localPK),
              try first.text(AppleBooksSchema.Collection.collectionID) == collectionID else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Collection.localPK)
        }
        if try statement.step() {
            throw StableIdentityError.ambiguousCollectionID
        }
        return try getByLocalPK(localPK)
    }

    func semanticBooks(in collection: SemanticCollection) throws -> [BookSummary] {
        let memberSchema = try AppleBooksSchema.inspect(.collectionMembers, on: connection)
        _ = try AppleBooksSchema.inspect(.collectionMemberBooks, on: connection)
        var projection = [AppleBooksSchema.Member.localPK]
        projection += SQLiteTextProjection.exact(
            AppleBooksSchema.Member.assetID,
            alias: "memberAssetID",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
        )
        var order: [String] = []
        if memberSchema.contains(AppleBooksSchema.Member.sortKey) {
            projection.append(AppleBooksSchema.Member.sortKey)
            order.append(AppleBooksSchema.Member.sortKey)
        }
        order.append(AppleBooksSchema.Member.localPK)
        let statement = try connection.prepare("""
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.collectionMembers.rawValue)
        WHERE \(AppleBooksSchema.Member.collection) = ?
        ORDER BY \(order.joined(separator: ", "))
        """)
        try statement.bind(collection.localPK, at: 1)
        let books = BookQueries(connection: connection)
        var resolved: [BookSummary] = []
        var seenLocalPKs = Set<Int64>()
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            let assetID: String
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "memberAssetID",
                column: AppleBooksSchema.Member.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value):
                assetID = value
            case .value, .null, .oversized:
                continue
            }
            for book in try books.semanticSummaries(assetID: assetID) {
                if seenLocalPKs.insert(book.localPK).inserted { resolved.append(book) }
            }
        }
        return resolved
    }

    func books(in collection: Collection) throws -> [Book] {
        let memberSchema = try AppleBooksSchema.inspect(.collectionMembers, on: connection)
        _ = try AppleBooksSchema.inspect(.collectionMemberBooks, on: connection)

        var projection = [AppleBooksSchema.Member.localPK, AppleBooksSchema.Member.assetID]
        if memberSchema.contains(AppleBooksSchema.Member.sortKey) {
            projection.append(AppleBooksSchema.Member.sortKey)
        }
        var order: [String] = []
        if memberSchema.contains(AppleBooksSchema.Member.sortKey) {
            order.append(AppleBooksSchema.Member.sortKey)
        }
        order.append(AppleBooksSchema.Member.localPK)

        let sql = """
        SELECT \(projection.joined(separator: ", "))
        FROM \(AppleBooksTable.collectionMembers.rawValue)
        WHERE \(AppleBooksSchema.Member.collection) = ?
        ORDER BY \(order.joined(separator: ", "))
        """
        let statement = try connection.prepare(sql)
        try statement.bind(collection.localPK, at: 1)

        let books = BookQueries(connection: connection)
        var resolved: [Book] = []
        var seenLocalPKs = Set<Int64>()
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let assetID = try row.text(AppleBooksSchema.Member.assetID) else {
                continue
            }
            for book in try books.getByAssetID(assetID).sorted(by: { $0.localPK < $1.localPK }) {
                if seenLocalPKs.insert(book.localPK).inserted {
                    resolved.append(book)
                }
            }
        }
        return resolved
    }

    private func semanticQuery(
        _ filter: Filter,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [SemanticCollection] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        var projection = [AppleBooksSchema.Collection.localPK]
        if schema.contains(AppleBooksSchema.Collection.collectionID) {
            projection += SQLiteTextProjection.exact(
                AppleBooksSchema.Collection.collectionID,
                alias: "collectionID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        if schema.contains(AppleBooksSchema.Collection.title) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Collection.title,
                alias: "collectionTitle",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        }
        if schema.contains(AppleBooksSchema.Collection.details) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Collection.details,
                alias: "collectionDetails",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.detail
            )
        }
        for column in [
            AppleBooksSchema.Collection.isDeleted,
            AppleBooksSchema.Collection.isHidden,
            AppleBooksSchema.Collection.isPlaceholder,
            AppleBooksSchema.Collection.sortKey,
            AppleBooksSchema.Collection.sortMode,
            AppleBooksSchema.Collection.viewMode,
            AppleBooksSchema.Collection.lastModificationDate,
            AppleBooksSchema.Collection.localModificationDate,
        ] where schema.contains(column) {
            projection.append(column)
        }
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.collections.rawValue)"
        sql += " WHERE \(AppleBooksSchema.Collection.isDeleted) = 0"
        switch filter {
        case .none: break
        case .localPK: sql += " AND \(AppleBooksSchema.Collection.localPK) = ?"
        case .collectionID: sql += " AND \(AppleBooksSchema.Collection.collectionID) = ? COLLATE BINARY"
        case .title: sql += " AND \(AppleBooksSchema.Collection.title) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        }
        var order: [String] = []
        if schema.contains(AppleBooksSchema.Collection.title) {
            order += [
                "\(AppleBooksSchema.Collection.title) IS NULL",
                "\(AppleBooksSchema.Collection.title) COLLATE NOCASE",
            ]
        }
        order.append(AppleBooksSchema.Collection.localPK)
        sql += " ORDER BY \(order.joined(separator: ", "))"
        if limit != nil { sql += " LIMIT ? OFFSET ?" }
        else if offset > 0 { sql += " LIMIT -1 OFFSET ?" }
        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        switch filter {
        case .none: break
        case let .localPK(value):
            try statement.bind(value, at: index); index += 1
        case let .collectionID(value):
            try statement.bind(value, at: index); index += 1
        case let .title(value):
            try statement.bind(literalContainsPattern(value), at: index); index += 1
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
            try statement.bind(Int64(offset), at: index + 1)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: index)
        }
        var result: [SemanticCollection] = []
        while try statement.step() {
            result.append(try decodeSemantic(SQLiteRow(statement: statement), schema: schema))
        }
        return result
    }

    private func decodeSemantic(_ row: SQLiteRow, schema: SchemaAvailability) throws -> SemanticCollection {
        guard let localPK = try row.int64(AppleBooksSchema.Collection.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Collection.localPK)
        }
        let collectionID: String?
        if schema.contains(AppleBooksSchema.Collection.collectionID) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "collectionID",
                column: AppleBooksSchema.Collection.collectionID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value): collectionID = value
            case .value, .null, .oversized: collectionID = nil
            }
        } else { collectionID = nil }
        func bounded(_ column: String, alias: String, budget: Int) throws -> BoundedSQLiteText {
            guard schema.contains(column) else {
                return BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
            }
            return try SQLiteTextProjection.decodeBounded(row, alias: alias, column: column, maximumUTF8Bytes: budget)
        }
        let title = try bounded(AppleBooksSchema.Collection.title, alias: "collectionTitle", budget: SQLiteSemanticTextBudget.metadata)
        let details = try bounded(AppleBooksSchema.Collection.details, alias: "collectionDetails", budget: SQLiteSemanticTextBudget.detail)
        var truncated: [String] = []
        if title.wasByteTruncated { truncated.append("title") }
        if details.wasByteTruncated { truncated.append("details") }
        func int64(_ column: String) throws -> Int64? { schema.contains(column) ? try row.int64(column) : nil }
        func date(_ column: String) throws -> Date? {
            guard schema.contains(column) else { return nil }
            return CoreDataTime.date(from: try row.double(column))
        }
        return SemanticCollection(
            localPK: localPK,
            collectionID: collectionID,
            title: title.value,
            details: details.value,
            isDeleted: try int64(AppleBooksSchema.Collection.isDeleted).map { $0 != 0 },
            isHidden: try int64(AppleBooksSchema.Collection.isHidden).map { $0 != 0 },
            isPlaceholder: try int64(AppleBooksSchema.Collection.isPlaceholder).map { $0 != 0 },
            sortKey: try int64(AppleBooksSchema.Collection.sortKey),
            sortMode: try int64(AppleBooksSchema.Collection.sortMode),
            viewMode: try int64(AppleBooksSchema.Collection.viewMode),
            lastModificationDate: try date(AppleBooksSchema.Collection.lastModificationDate),
            localModificationDate: try date(AppleBooksSchema.Collection.localModificationDate),
            byteTruncatedFields: truncated
        )
    }

    private func query(
        _ filter: Filter,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [Collection] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let projection = [AppleBooksSchema.Collection.localPK]
            + AppleBooksSchema.Collection.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.collections.rawValue)"
        sql += " WHERE \(AppleBooksSchema.Collection.isDeleted) = 0"

        switch filter {
        case .none:
            break
        case .localPK:
            sql += " AND \(AppleBooksSchema.Collection.localPK) = ?"
        case .collectionID:
            sql += " AND \(AppleBooksSchema.Collection.collectionID) = ? COLLATE BINARY"
        case .title:
            sql += " AND \(AppleBooksSchema.Collection.title) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        }

        var order: [String] = []
        if schema.contains(AppleBooksSchema.Collection.title) {
            order += [
                "\(AppleBooksSchema.Collection.title) IS NULL",
                "\(AppleBooksSchema.Collection.title) COLLATE NOCASE",
            ]
        }
        order.append(AppleBooksSchema.Collection.localPK)
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
        case let .collectionID(value):
            try statement.bind(value, at: index)
            index += 1
        case let .title(value):
            try statement.bind(literalContainsPattern(value), at: index)
            index += 1
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
            try statement.bind(Int64(offset), at: index + 1)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: index)
        }

        var collections: [Collection] = []
        while try statement.step() {
            collections.append(try decode(SQLiteRow(statement: statement), schema: schema))
        }
        return collections
    }

    private func decode(_ row: SQLiteRow, schema: SchemaAvailability) throws -> Collection {
        guard let localPK = try row.int64(AppleBooksSchema.Collection.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Collection.localPK)
        }

        func text(_ column: String) throws -> String? {
            schema.contains(column) ? try row.text(column) : nil
        }
        func int64(_ column: String) throws -> Int64? {
            schema.contains(column) ? try row.int64(column) : nil
        }
        func bool(_ column: String) throws -> Bool? {
            try int64(column).map { $0 != 0 }
        }
        func date(_ column: String) throws -> Date? {
            guard schema.contains(column) else { return nil }
            return CoreDataTime.date(from: try row.double(column))
        }

        return Collection(
            localPK: localPK,
            collectionID: try text(AppleBooksSchema.Collection.collectionID),
            title: try text(AppleBooksSchema.Collection.title),
            details: try text(AppleBooksSchema.Collection.details),
            isDeleted: try bool(AppleBooksSchema.Collection.isDeleted),
            isHidden: try bool(AppleBooksSchema.Collection.isHidden),
            isPlaceholder: try bool(AppleBooksSchema.Collection.isPlaceholder),
            sortKey: try int64(AppleBooksSchema.Collection.sortKey),
            sortMode: try int64(AppleBooksSchema.Collection.sortMode),
            viewMode: try int64(AppleBooksSchema.Collection.viewMode),
            lastModificationDate: try date(AppleBooksSchema.Collection.lastModificationDate),
            localModificationDate: try date(AppleBooksSchema.Collection.localModificationDate)
        )
    }
}

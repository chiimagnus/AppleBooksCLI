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

    func getUniqueByCollectionID(_ collectionID: String) throws -> Collection? {
        let matches = try query(.collectionID(collectionID), capability: .collectionIDLookup, limit: nil, offset: 0)
        guard matches.count <= 1 else { throw StableIdentityError.ambiguousCollectionID }
        return matches.first
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
            sql += " AND \(AppleBooksSchema.Collection.collectionID) = ?"
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
        func bool(_ column: String) throws -> Bool? {
            guard schema.contains(column) else { return nil }
            return try row.int64(column).map { $0 != 0 }
        }

        return Collection(
            localPK: localPK,
            collectionID: try text(AppleBooksSchema.Collection.collectionID),
            title: try text(AppleBooksSchema.Collection.title),
            details: try text(AppleBooksSchema.Collection.details),
            isDeleted: try bool(AppleBooksSchema.Collection.isDeleted),
            isHidden: try bool(AppleBooksSchema.Collection.isHidden)
        )
    }
}

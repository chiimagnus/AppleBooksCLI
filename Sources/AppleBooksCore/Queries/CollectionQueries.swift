import Foundation

struct CollectionQueries {
    private enum Filter {
        case none
        case title(String)
    }

    let connection: SQLiteConnection

    func semanticGetByLocalPK(_ localPK: Int64) throws -> SemanticCollection? {
        let schema = try AppleBooksSchema.inspect(.collectionBase, on: connection)
        let projection = semanticProjection(schema: schema, alias: "item")
        let statement = try connection.prepare("""
            SELECT \(projection.joined(separator: ", "))
            FROM \(AppleBooksTable.collections.rawValue) AS item
            WHERE item.\(AppleBooksSchema.Collection.localPK) = ?
              AND item.\(AppleBooksSchema.Collection.isDeleted) = 0
            LIMIT 1
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        return try decodeSemantic(SQLiteRow(statement: statement), schema: schema)
    }

    func semanticListPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<SemanticCollectionSummary> {
        try semanticPage(.none, capability: .collectionBase, limit: limit, cursor: cursor)
    }

    func semanticSearchTitlePage(
        _ text: String,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<SemanticCollectionSummary> {
        try semanticPage(.title(text), capability: .collectionTitleSearch, limit: limit, cursor: cursor)
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

    func semanticBooksPage(
        in collection: SemanticCollection,
        limit: Int? = nil,
        cursor: String? = nil
    ) throws -> CursorPage<BookSummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let memberSchema = try AppleBooksSchema.inspect(.collectionMembers, on: connection)
        let bookSchema = try AppleBooksSchema.inspect(.collectionMemberBooks, on: connection)
        let beforeGeneration = try collectionCursorGeneration()
        let fingerprint = try CursorQueryFingerprint.make(
            kind: "collections.books",
            fields: [
                CursorFingerprintField("collection.local-pk", .signed(collection.localPK)),
                CursorFingerprintField("order.version", .unsigned(1)),
                CursorFingerprintField("order.sort-key", .bool(memberSchema.contains(AppleBooksSchema.Member.sortKey))),
            ]
        )
        let session = try CursorPaginationSession(
            cursor: cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )

        let cursorBookPK: Int64?
        if let locator = session.locator {
            guard locator.words.count == 1 else { throw CursorPaginationError.invalidCursor }
            cursorBookPK = Int64(bitPattern: locator.words[0])
            guard try membershipCursorExists(
                collectionLocalPK: collection.localPK,
                bookLocalPK: cursorBookPK!,
                memberSchema: memberSchema
            ) else {
                throw CursorPaginationError.staleCursor
            }
        } else {
            cursorBookPK = nil
        }

        let candidates = try semanticMembershipCandidates(
            collectionLocalPK: collection.localPK,
            memberSchema: memberSchema,
            bookSchema: bookSchema,
            cursorBookPK: cursorBookPK,
            limit: effectiveLimit + 1
        )
        let afterGeneration = try collectionCursorGeneration()
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            session: session,
            afterGeneration: afterGeneration,
            locator: { try .rowID($0.localPK) }
        )
    }

    private func semanticMembershipCandidates(
        collectionLocalPK: Int64,
        memberSchema: SchemaAvailability,
        bookSchema: SchemaAvailability,
        cursorBookPK: Int64?,
        limit: Int?
    ) throws -> [BookSummary] {
        let decoder = BookQueries(connection: connection)
        let projection = decoder.summaryProjection(schema: bookSchema, alias: "b")
        var ctes = [canonicalMembershipCTE(memberSchema: memberSchema)]
        if cursorBookPK != nil {
            ctes.append("cursor_row AS (SELECT * FROM canonical_members WHERE bookPK = ?)")
        }
        var sql = "WITH \(ctes.joined(separator: ", ")) "
        sql += "SELECT \(projection.joined(separator: ", ")) "
        sql += "FROM canonical_members AS cm "
        sql += "JOIN \(AppleBooksTable.books.rawValue) AS b ON b.\(AppleBooksSchema.Book.localPK) = cm.bookPK "
        if cursorBookPK != nil {
            sql += "CROSS JOIN cursor_row AS cursor "
            sql += "WHERE \(membershipKeysetPredicate(memberSchema: memberSchema, itemAlias: "cm", cursorAlias: "cursor")) "
        }
        sql += "ORDER BY \(membershipOrder(memberSchema: memberSchema, alias: "cm").joined(separator: ", "))"
        if limit != nil { sql += " LIMIT ?" }

        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        try statement.bind(collectionLocalPK, at: index)
        index += 1
        if let cursorBookPK {
            try statement.bind(cursorBookPK, at: index)
            index += 1
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
        }
        var result: [BookSummary] = []
        if let limit { result.reserveCapacity(limit) }
        while try statement.step() {
            result.append(try decoder.decodeSummary(SQLiteRow(statement: statement), schema: bookSchema))
        }
        return result
    }

    private func membershipCursorExists(
        collectionLocalPK: Int64,
        bookLocalPK: Int64,
        memberSchema: SchemaAvailability
    ) throws -> Bool {
        let statement = try connection.prepare("""
            WITH \(canonicalMembershipCTE(memberSchema: memberSchema))
            SELECT 1 AS present
            FROM canonical_members
            WHERE bookPK = ?
            LIMIT 2
            """)
        try statement.bind(collectionLocalPK, at: 1)
        try statement.bind(bookLocalPK, at: 2)
        guard try statement.step() else { return false }
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return true
    }

    private func canonicalMembershipCTE(memberSchema: SchemaAvailability) -> String {
        let hasSortKey = memberSchema.contains(AppleBooksSchema.Member.sortKey)
        let sortProjection = hasSortKey ? "m.\(AppleBooksSchema.Member.sortKey) AS memberSortKey," : ""
        let earlier: String
        if hasSortKey {
            let itemSort = "m.\(AppleBooksSchema.Member.sortKey)"
            let earlierSort = "earlier.\(AppleBooksSchema.Member.sortKey)"
            earlier = """
            ((\(earlierSort) IS NULL AND \(itemSort) IS NOT NULL)
             OR (\(earlierSort) IS NULL AND \(itemSort) IS NULL AND earlier.\(AppleBooksSchema.Member.localPK) < m.\(AppleBooksSchema.Member.localPK))
             OR (\(earlierSort) IS NOT NULL AND \(itemSort) IS NOT NULL AND
                 (\(earlierSort) < \(itemSort)
                  OR (\(earlierSort) = \(itemSort) AND earlier.\(AppleBooksSchema.Member.localPK) < m.\(AppleBooksSchema.Member.localPK)))))
            """
        } else {
            earlier = "earlier.\(AppleBooksSchema.Member.localPK) < m.\(AppleBooksSchema.Member.localPK)"
        }
        return """
        canonical_members AS (
          SELECT m.\(AppleBooksSchema.Member.localPK) AS memberPK,
                 \(sortProjection)
                 source_book.\(AppleBooksSchema.Book.localPK) AS bookPK
          FROM \(AppleBooksTable.collectionMembers.rawValue) AS m
          JOIN \(AppleBooksTable.books.rawValue) AS source_book
            ON source_book.\(AppleBooksSchema.Book.assetID) = m.\(AppleBooksSchema.Member.assetID) COLLATE BINARY
          WHERE m.\(AppleBooksSchema.Member.collection) = ?
            AND NOT EXISTS (
              SELECT 1
              FROM \(AppleBooksTable.collectionMembers.rawValue) AS earlier
              WHERE earlier.\(AppleBooksSchema.Member.collection) = m.\(AppleBooksSchema.Member.collection)
                AND earlier.\(AppleBooksSchema.Member.assetID) = m.\(AppleBooksSchema.Member.assetID) COLLATE BINARY
                AND (\(earlier))
            )
        )
        """
    }

    private func membershipOrder(memberSchema: SchemaAvailability, alias: String) -> [String] {
        var order: [String] = []
        if memberSchema.contains(AppleBooksSchema.Member.sortKey) {
            order.append("\(alias).memberSortKey ASC")
        }
        order.append("\(alias).memberPK ASC")
        order.append("\(alias).bookPK ASC")
        return order
    }

    private func membershipKeysetPredicate(
        memberSchema: SchemaAvailability,
        itemAlias: String,
        cursorAlias: String
    ) -> String {
        let itemTie = "(\(itemAlias).memberPK > \(cursorAlias).memberPK OR (\(itemAlias).memberPK = \(cursorAlias).memberPK AND \(itemAlias).bookPK > \(cursorAlias).bookPK))"
        guard memberSchema.contains(AppleBooksSchema.Member.sortKey) else { return itemTie }
        return """
        ((\(cursorAlias).memberSortKey IS NULL AND
           ((\(itemAlias).memberSortKey IS NULL AND \(itemTie)) OR \(itemAlias).memberSortKey IS NOT NULL))
         OR
         (\(cursorAlias).memberSortKey IS NOT NULL AND \(itemAlias).memberSortKey IS NOT NULL AND
           (\(itemAlias).memberSortKey > \(cursorAlias).memberSortKey
            OR (\(itemAlias).memberSortKey = \(cursorAlias).memberSortKey AND \(itemTie)))))
        """
    }

    private func semanticPage(
        _ filter: Filter,
        capability: SchemaCapability,
        limit: Int?,
        cursor: String?
    ) throws -> CursorPage<SemanticCollectionSummary> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let schema = try AppleBooksSchema.inspect(capability, on: connection)
        let beforeGeneration = try collectionCursorGeneration()
        let fingerprint = try CursorQueryFingerprint.make(
            kind: collectionCursorKind(filter),
            fields: collectionCursorFingerprintFields(filter: filter, schema: schema)
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
            guard try semanticCollectionCursorRowExists(filter, localPK: cursorPK!, schema: schema) else {
                throw CursorPaginationError.staleCursor
            }
        } else {
            cursorPK = nil
        }

        let candidates = try semanticCollectionCandidates(
            filter,
            schema: schema,
            cursorPK: cursorPK,
            limit: effectiveLimit + 1
        )
        let afterGeneration = try collectionCursorGeneration()
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            session: session,
            afterGeneration: afterGeneration,
            locator: { try .rowID($0.localPK) }
        )
    }

    private func collectionCursorKind(_ filter: Filter) -> String {
        switch filter {
        case .none: "collections.list"
        case .title: "collections.search"
        }
    }

    private func collectionCursorFingerprintFields(
        filter: Filter,
        schema: SchemaAvailability
    ) -> [CursorFingerprintField] {
        var fields = [
            CursorFingerprintField("order.version", .unsigned(1)),
            CursorFingerprintField("schema.collection-id", .bool(schema.contains(AppleBooksSchema.Collection.collectionID))),
            CursorFingerprintField("schema.title", .bool(schema.contains(AppleBooksSchema.Collection.title))),
        ]
        if case let .title(value) = filter {
            fields.append(CursorFingerprintField("filter.title", .string(value)))
        }
        return fields
    }

    private func semanticCollectionCandidates(
        _ filter: Filter,
        schema: SchemaAvailability,
        cursorPK: Int64?,
        limit: Int
    ) throws -> [SemanticCollectionSummary] {
        let projection = semanticSummaryProjection(schema: schema, alias: "item")
        var sql = ""
        if cursorPK != nil {
            var cursorColumns = ["\(AppleBooksSchema.Collection.localPK) AS cursorPK"]
            if schema.contains(AppleBooksSchema.Collection.title) {
                cursorColumns.append("\(AppleBooksSchema.Collection.title) AS cursorTitle")
            }
            sql += "WITH cursor_row AS (SELECT \(cursorColumns.joined(separator: ", ")) FROM \(AppleBooksTable.collections.rawValue) WHERE \(AppleBooksSchema.Collection.localPK) = ?) "
        }
        sql += "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.collections.rawValue) AS item"
        if cursorPK != nil { sql += " CROSS JOIN cursor_row AS cursor" }
        var predicates = ["item.\(AppleBooksSchema.Collection.isDeleted) = 0"]
        if case .title = filter {
            predicates.append("item.\(AppleBooksSchema.Collection.title) LIKE ? ESCAPE '\\' COLLATE NOCASE")
        }
        if cursorPK != nil {
            predicates.append(collectionKeysetPredicate(schema: schema, itemAlias: "item", cursorAlias: "cursor"))
        }
        sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        sql += " ORDER BY \(collectionOrder(schema: schema, alias: "item").joined(separator: ", "))"
        sql += " LIMIT ?"

        let statement = try connection.prepare(sql)
        var index: Int32 = 1
        if let cursorPK {
            try statement.bind(cursorPK, at: index)
            index += 1
        }
        if case let .title(value) = filter {
            try statement.bind(literalContainsPattern(value), at: index)
            index += 1
        }
        try statement.bind(Int64(limit), at: index)
        var result: [SemanticCollectionSummary] = []
        result.reserveCapacity(limit)
        while try statement.step() {
            result.append(try decodeSemanticSummary(SQLiteRow(statement: statement), schema: schema))
        }
        return result
    }

    private func semanticCollectionCursorRowExists(
        _ filter: Filter,
        localPK: Int64,
        schema: SchemaAvailability
    ) throws -> Bool {
        var sql = "SELECT 1 AS present FROM \(AppleBooksTable.collections.rawValue) WHERE \(AppleBooksSchema.Collection.localPK) = ? AND \(AppleBooksSchema.Collection.isDeleted) = 0"
        if case .title = filter {
            sql += " AND \(AppleBooksSchema.Collection.title) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        }
        sql += " LIMIT 2"
        let statement = try connection.prepare(sql)
        try statement.bind(localPK, at: 1)
        if case let .title(value) = filter {
            try statement.bind(literalContainsPattern(value), at: 2)
        }
        guard try statement.step() else { return false }
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return true
    }

    private func collectionOrder(schema: SchemaAvailability, alias: String) -> [String] {
        var order: [String] = []
        if schema.contains(AppleBooksSchema.Collection.title) {
            order.append("\(alias).\(AppleBooksSchema.Collection.title) IS NULL")
            order.append("\(alias).\(AppleBooksSchema.Collection.title) COLLATE NOCASE ASC")
        }
        order.append("\(alias).\(AppleBooksSchema.Collection.localPK) ASC")
        return order
    }

    private func collectionKeysetPredicate(
        schema: SchemaAvailability,
        itemAlias: String,
        cursorAlias: String
    ) -> String {
        let itemPK = "\(itemAlias).\(AppleBooksSchema.Collection.localPK)"
        let cursorPK = "\(cursorAlias).cursorPK"
        guard schema.contains(AppleBooksSchema.Collection.title) else {
            return "\(itemPK) > \(cursorPK)"
        }
        let itemTitle = "\(itemAlias).\(AppleBooksSchema.Collection.title)"
        let cursorTitle = "\(cursorAlias).cursorTitle"
        return """
        ((\(cursorTitle) IS NOT NULL AND
           (\(itemTitle) IS NULL
            OR (\(itemTitle) IS NOT NULL AND
                (\(itemTitle) COLLATE NOCASE > \(cursorTitle) COLLATE NOCASE
                 OR (\(itemTitle) COLLATE NOCASE = \(cursorTitle) COLLATE NOCASE AND \(itemPK) > \(cursorPK))))))
         OR
         (\(cursorTitle) IS NULL AND \(itemTitle) IS NULL AND \(itemPK) > \(cursorPK)))
        """
    }

    private func collectionCursorGeneration() throws -> CursorGeneration {
        try CursorGeneration.compose([
            .sqlite(label: "library", databaseURL: connection.databaseURL),
        ])
    }

    private func semanticSummaryProjection(schema: SchemaAvailability, alias: String) -> [String] {
        let prefix = "\(alias)."
        var projection = ["\(prefix)\(AppleBooksSchema.Collection.localPK) AS \(AppleBooksSchema.Collection.localPK)"]
        if schema.contains(AppleBooksSchema.Collection.collectionID) {
            projection += SQLiteTextProjection.exact(
                "\(prefix)\(AppleBooksSchema.Collection.collectionID)",
                alias: "collectionID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
            projection += SQLiteTextProjection.exact(
                "CASE WHEN length(CAST(\(prefix)\(AppleBooksSchema.Collection.collectionID) AS BLOB)) <= 128 THEN \(prefix)\(AppleBooksSchema.Collection.collectionID) END",
                alias: "editPolicyCollectionID",
                maximumUTF8Bytes: 128
            )
        }
        if schema.contains(AppleBooksSchema.Collection.title) {
            projection += SQLiteTextProjection.bounded(
                "\(prefix)\(AppleBooksSchema.Collection.title)",
                alias: "collectionTitle",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        }
        return projection
    }

    private func decodeSemanticSummary(
        _ row: SQLiteRow,
        schema: SchemaAvailability
    ) throws -> SemanticCollectionSummary {
        guard let localPK = try row.int64(AppleBooksSchema.Collection.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Collection.localPK)
        }
        let identity = try decodeSemanticIdentity(row, schema: schema)
        let title: BoundedSQLiteText
        if schema.contains(AppleBooksSchema.Collection.title) {
            title = try SQLiteTextProjection.decodeBounded(
                row,
                alias: "collectionTitle",
                column: AppleBooksSchema.Collection.title,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        } else {
            title = BoundedSQLiteText(value: nil, originalUTF8ByteCount: nil, wasByteTruncated: false)
        }
        return SemanticCollectionSummary(
            localPK: localPK,
            collectionID: identity.publicID,
            title: title.value,
            canEditCollection: identity.capabilities.canEditCollection,
            canEditMembership: identity.capabilities.canEditMembership,
            byteTruncatedFields: title.wasByteTruncated ? ["title"] : []
        )
    }

    private func decodeSemanticIdentity(
        _ row: SQLiteRow,
        schema: SchemaAvailability
    ) throws -> (publicID: String?, capabilities: CollectionEditCapabilities) {
        guard schema.contains(AppleBooksSchema.Collection.collectionID) else {
            return (nil, CollectionIdentityEditPolicy.capabilities(for: nil))
        }

        let publicID: String?
        switch try SQLiteTextProjection.decodeExact(
            row,
            alias: "collectionID",
            column: AppleBooksSchema.Collection.collectionID,
            maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
        ) {
        case let .value(value) where PublicStableIdentityPolicy.isEligible(value):
            publicID = value
        case .value, .null, .oversized:
            publicID = nil
        }

        let rawPolicyID: String?
        switch try SQLiteTextProjection.decodeExact(
            row,
            alias: "editPolicyCollectionID",
            column: AppleBooksSchema.Collection.collectionID,
            maximumUTF8Bytes: 128
        ) {
        case let .value(value): rawPolicyID = value
        case .null, .oversized: rawPolicyID = nil
        }
        return (publicID, CollectionIdentityEditPolicy.capabilities(for: rawPolicyID))
    }

    private func semanticProjection(schema: SchemaAvailability, alias: String) -> [String] {
        let prefix = "\(alias)."
        var projection = semanticSummaryProjection(schema: schema, alias: alias)
        if schema.contains(AppleBooksSchema.Collection.details) {
            projection += SQLiteTextProjection.bounded(
                "\(prefix)\(AppleBooksSchema.Collection.details)",
                alias: "collectionDetails",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.detail
            )
        }
        if schema.contains(AppleBooksSchema.Collection.isHidden) {
            projection.append("\(prefix)\(AppleBooksSchema.Collection.isHidden) AS \(AppleBooksSchema.Collection.isHidden)")
        }
        return projection
    }

    private func decodeSemantic(_ row: SQLiteRow, schema: SchemaAvailability) throws -> SemanticCollection {
        guard let localPK = try row.int64(AppleBooksSchema.Collection.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Collection.localPK)
        }
        let identity = try decodeSemanticIdentity(row, schema: schema)
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
        let isHidden = schema.contains(AppleBooksSchema.Collection.isHidden)
            ? try row.int64(AppleBooksSchema.Collection.isHidden).map { $0 != 0 }
            : nil
        return SemanticCollection(
            localPK: localPK,
            collectionID: identity.publicID,
            title: title.value,
            details: details.value,
            isHidden: isHidden,
            canEditCollection: identity.capabilities.canEditCollection,
            canEditMembership: identity.capabilities.canEditMembership,
            byteTruncatedFields: truncated
        )
    }

}

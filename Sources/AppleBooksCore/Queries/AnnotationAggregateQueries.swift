struct UserAnnotationAssetCount: Equatable, Sendable {
    let rawAssetID: String?
    let count: Int
    let identityUnavailable: Bool

    init(rawAssetID: String?, count: Int, identityUnavailable: Bool = false) {
        self.rawAssetID = rawAssetID
        self.count = count
        self.identityUnavailable = identityUnavailable
    }
}

enum AnnotationAggregateQueryError: Error, Equatable, Sendable {
    case batchTooLarge
}

struct AnnotationAggregateQueries {
    static let maximumIdentityBatch = 100

    let connection: SQLiteConnection

    func totalUserAnnotations() throws -> Int {
        _ = try AppleBooksSchema.inspect(.annotationUserBase, on: connection)
        let statement = try connection.prepare("""
        SELECT COUNT(*) AS count
        FROM \(AppleBooksTable.annotations.rawValue)
        WHERE \(userScopePredicate)
        """)
        return try decodeCount(statement)
    }

    func userAnnotationCounts(assetIDs: [String]) throws -> [String: Int] {
        guard assetIDs.count <= Self.maximumIdentityBatch else {
            throw AnnotationAggregateQueryError.batchTooLarge
        }
        let unique = Array(Set(assetIDs))
        guard unique.isEmpty == false else { return [:] }
        _ = try AppleBooksSchema.inspect(.annotationByAssetID, on: connection)
        let placeholders = Array(repeating: "?", count: unique.count).joined(separator: ",")
        let statement = try connection.prepare("""
        SELECT \(AppleBooksSchema.Annotation.assetID) AS assetID, COUNT(*) AS count
        FROM \(AppleBooksTable.annotations.rawValue)
        WHERE \(userScopePredicate)
          AND \(AppleBooksSchema.Annotation.assetID) COLLATE BINARY IN (\(placeholders))
        GROUP BY \(AppleBooksSchema.Annotation.assetID) COLLATE BINARY
        """)
        for (offset, assetID) in unique.enumerated() {
            try statement.bind(assetID, at: Int32(offset + 1))
        }
        var result: [String: Int] = [:]
        result.reserveCapacity(unique.count)
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let assetID = try row.text("assetID"),
                  let rawCount = try row.int64("count"), rawCount >= 0 else {
                throw QueryDecodingError.nullRequiredColumn("annotation aggregate")
            }
            result[assetID] = Int(rawCount)
        }
        return result
    }

    func forEachUserAnnotationAssetCount(
        _ body: (UserAnnotationAssetCount) throws -> Void
    ) throws {
        _ = try AppleBooksSchema.inspect(.annotationByAssetID, on: connection)
        let identityProjection = SQLiteTextProjection.exact(
            AppleBooksSchema.Annotation.assetID,
            alias: "aggregateAssetID",
            maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
        ).joined(separator: ", ")
        let statement = try connection.prepare("""
        SELECT \(identityProjection), COUNT(*) AS count
        FROM \(AppleBooksTable.annotations.rawValue)
        WHERE \(userScopePredicate)
        GROUP BY \(AppleBooksSchema.Annotation.assetID) COLLATE BINARY
        ORDER BY \(AppleBooksSchema.Annotation.assetID) COLLATE BINARY
        """)
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            let identity = try SQLiteTextProjection.decodeExact(
                row,
                alias: "aggregateAssetID",
                column: AppleBooksSchema.Annotation.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
            guard let rawCount = try row.int64("count"), rawCount >= 0 else {
                throw QueryDecodingError.nullRequiredColumn("count")
            }
            let count = Int(rawCount)
            switch identity {
            case .null:
                try body(UserAnnotationAssetCount(rawAssetID: nil, count: count))
            case let .value(value):
                try body(UserAnnotationAssetCount(
                    rawAssetID: value,
                    count: count,
                    identityUnavailable: PublicStableIdentityPolicy.isEligible(value) == false
                ))
            case .oversized:
                try body(UserAnnotationAssetCount(rawAssetID: nil, count: count, identityUnavailable: true))
            }
        }
    }

    private var userScopePredicate: String {
        "\(AppleBooksSchema.Annotation.isDeleted) = 0 AND \(AppleBooksSchema.Annotation.type) != 3"
    }

    private func decodeCount(_ statement: SQLiteStatement) throws -> Int {
        guard try statement.step(),
              let rawCount = try SQLiteRow(statement: statement).int64("count"),
              rawCount >= 0,
              try statement.step() == false else {
            throw QueryDecodingError.nullRequiredColumn("count")
        }
        return Int(rawCount)
    }
}

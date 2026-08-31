import Foundation

struct AnnotationQueries {
    private enum Filter {
        case none
        case localPK(Int64)
        case uuid(String)
        case assetID(String)
        case style(Int64)
        case highlightedText(String)
        case note(String)
        case fullText(String)
        case creationRange(lower: Double?, upper: Double?)
    }

    let annotationConnection: SQLiteConnection
    let bookQueries: BookQueries
    let historicalAssets: HistoricalAssetMapping

    func list(limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.none, capability: .annotationUserBase, limit: limit, offset: offset)
    }

    func getByLocalPK(_ localPK: Int64) throws -> EnrichedAnnotation? {
        try query(.localPK(localPK), capability: .annotationUserBase, limit: 1, offset: 0).first
    }

    func getByUUID(_ uuid: String) throws -> [EnrichedAnnotation] {
        try query(.uuid(uuid), capability: .annotationByUUID, limit: nil, offset: 0)
    }

    func byAssetID(_ assetID: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.assetID(assetID), capability: .annotationByAssetID, limit: limit, offset: offset)
    }

    func byStyle(_ style: Int64, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.style(style), capability: .annotationByStyle, limit: limit, offset: offset)
    }

    func byColorName(_ name: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        let color = try AnnotationColor(name: name)
        return try byStyle(color.rawValue, limit: limit, offset: offset)
    }

    func searchHighlightedText(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.highlightedText(text), capability: .annotationHighlightedText, limit: limit, offset: offset)
    }

    func searchNote(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.note(text), capability: .annotationNote, limit: limit, offset: offset)
    }

    func searchText(_ text: String, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.fullText(text), capability: .annotationFullText, limit: limit, offset: offset)
    }

    func created(
        lowerInclusive: Date? = nil,
        upperExclusive: Date? = nil,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        if let lowerInclusive, let upperExclusive, lowerInclusive >= upperExclusive {
            throw AnnotationQueryInputError.invalidDateRange
        }
        return try query(
            .creationRange(
                lower: CoreDataTime.seconds(from: lowerInclusive),
                upper: CoreDataTime.seconds(from: upperExclusive)
            ),
            capability: .annotationByCreationDate,
            limit: limit,
            offset: offset
        )
    }

    private func query(
        _ filter: Filter,
        capability: SchemaCapability,
        limit: Int?,
        offset: Int
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        let schema = try AppleBooksSchema.inspect(capability, on: annotationConnection)
        let projection = [AppleBooksSchema.Annotation.localPK]
            + AppleBooksSchema.Annotation.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue)"
        sql += " WHERE \(AppleBooksSchema.Annotation.isDeleted) = 0"
        sql += " AND \(AppleBooksSchema.Annotation.type) != 3"

        switch filter {
        case .none:
            break
        case .localPK:
            sql += " AND \(AppleBooksSchema.Annotation.localPK) = ?"
        case .uuid:
            sql += " AND \(AppleBooksSchema.Annotation.uuid) = ?"
        case .assetID:
            sql += " AND \(AppleBooksSchema.Annotation.assetID) = ?"
        case .style:
            sql += " AND \(AppleBooksSchema.Annotation.style) = ?"
        case .highlightedText:
            sql += " AND \(AppleBooksSchema.Annotation.selectedText) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        case .note:
            sql += " AND \(AppleBooksSchema.Annotation.note) LIKE ? ESCAPE '\\' COLLATE NOCASE"
        case .fullText:
            sql += " AND ("
            sql += "\(AppleBooksSchema.Annotation.selectedText) LIKE ? ESCAPE '\\' COLLATE NOCASE"
            sql += " OR \(AppleBooksSchema.Annotation.representativeText) LIKE ? ESCAPE '\\' COLLATE NOCASE"
            sql += " OR \(AppleBooksSchema.Annotation.note) LIKE ? ESCAPE '\\' COLLATE NOCASE)"
        case let .creationRange(lower, upper):
            if lower != nil {
                sql += " AND \(AppleBooksSchema.Annotation.creationDate) >= ?"
            }
            if upper != nil {
                sql += " AND \(AppleBooksSchema.Annotation.creationDate) < ?"
            }
        }

        var order: [String] = []
        if schema.contains(AppleBooksSchema.Annotation.modificationDate) {
            order += [
                "\(AppleBooksSchema.Annotation.modificationDate) IS NULL",
                "\(AppleBooksSchema.Annotation.modificationDate) DESC",
            ]
        }
        if schema.contains(AppleBooksSchema.Annotation.creationDate) {
            order += [
                "\(AppleBooksSchema.Annotation.creationDate) IS NULL",
                "\(AppleBooksSchema.Annotation.creationDate) DESC",
            ]
        }
        order.append("\(AppleBooksSchema.Annotation.localPK) DESC")
        sql += " ORDER BY \(order.joined(separator: ", "))"

        if limit != nil {
            sql += " LIMIT ? OFFSET ?"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
        }

        let statement = try annotationConnection.prepare(sql)
        var index: Int32 = 1
        switch filter {
        case .none:
            break
        case let .localPK(value), let .style(value):
            try statement.bind(value, at: index)
            index += 1
        case let .uuid(value), let .assetID(value):
            try statement.bind(value, at: index)
            index += 1
        case let .highlightedText(value), let .note(value):
            try statement.bind(literalContainsPattern(value), at: index)
            index += 1
        case let .fullText(value):
            let pattern = literalContainsPattern(value)
            try statement.bind(pattern, at: index)
            try statement.bind(pattern, at: index + 1)
            try statement.bind(pattern, at: index + 2)
            index += 3
        case let .creationRange(lower, upper):
            if let lower {
                try statement.bind(lower, at: index)
                index += 1
            }
            if let upper {
                try statement.bind(upper, at: index)
                index += 1
            }
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
            try statement.bind(Int64(offset), at: index + 1)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: index)
        }

        var results: [EnrichedAnnotation] = []
        while try statement.step() {
            let annotation = try Self.decode(SQLiteRow(statement: statement), schema: schema)
            results.append(try enrich(annotation))
        }
        return results
    }

    static func decode(_ row: SQLiteRow, schema: SchemaAvailability) throws -> Annotation {
        guard let localPK = try row.int64(AppleBooksSchema.Annotation.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Annotation.localPK)
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

        let rawCFI = try text(AppleBooksSchema.Annotation.location)
        return Annotation(
            localPK: localPK,
            uuid: try text(AppleBooksSchema.Annotation.uuid),
            rawAssetID: try text(AppleBooksSchema.Annotation.assetID),
            isDeleted: try bool(AppleBooksSchema.Annotation.isDeleted),
            isUnderline: try bool(AppleBooksSchema.Annotation.isUnderline),
            style: try int64(AppleBooksSchema.Annotation.style),
            type: try int64(AppleBooksSchema.Annotation.type),
            createdAt: try date(AppleBooksSchema.Annotation.creationDate),
            modifiedAt: try date(AppleBooksSchema.Annotation.modificationDate),
            representativeText: try text(AppleBooksSchema.Annotation.representativeText),
            selectedText: try text(AppleBooksSchema.Annotation.selectedText),
            note: try text(AppleBooksSchema.Annotation.note),
            location: rawCFI.map(Location.init(rawCFI:)),
            chapterHint: try text(AppleBooksSchema.Annotation.chapterHint),
            physicalLocation: try int64(AppleBooksSchema.Annotation.physicalLocation),
            rangeStart: try int64(AppleBooksSchema.Annotation.rangeStart),
            rangeEnd: try int64(AppleBooksSchema.Annotation.rangeEnd)
        )
    }

    private func enrich(_ annotation: Annotation) throws -> EnrichedAnnotation {
        guard let assetID = annotation.rawAssetID else {
            return EnrichedAnnotation(annotation: annotation, source: .unmapped)
        }

        do {
            let matches = try bookQueries.getByAssetID(assetID)
            if matches.count == 1, let book = matches.first {
                return EnrichedAnnotation(annotation: annotation, source: .currentLibrary(book))
            }
        } catch is SchemaCompatibilityError {
            // ponytail: schema drift only disables current-library enrichment; canonical AEAnnotation rows remain authoritative.
        }

        if let metadata = historicalAssets.metadata(for: assetID) {
            return EnrichedAnnotation(annotation: annotation, source: .historicalInferred(metadata))
        }
        return EnrichedAnnotation(annotation: annotation, source: .unmapped)
    }
}

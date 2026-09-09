import Foundation

struct AnnotationQueries {
    private enum QueryOrder {
        case standard
        case modificationRecent
        case creationRecent
    }

    private enum SemanticTextMode {
        case preview
        case detail

        var selectedTextBudget: Int {
            switch self {
            case .preview: SQLiteSemanticTextBudget.preview
            case .detail: SQLiteSemanticTextBudget.detail
            }
        }

        var noteBudget: Int { selectedTextBudget }
    }

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
    let historicalAssets: HistoricalAssets

    func list(scope: AnnotationScope = .user, limit: Int? = nil, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(.none, capability: .annotationUserBase, scope: scope, limit: limit, offset: offset)
    }

    func page(scope: AnnotationScope = .activeRaw, limit: Int? = nil, offset: Int = 0) throws -> Page<EnrichedAnnotation> {
        let effectiveLimit = try resolvedPageLimit(limit, default: 50, offset: offset)
        let total = try count(scope: scope, style: nil, capability: .annotationUserBase)
        let items = try list(scope: scope, limit: effectiveLimit, offset: offset)
        return Page(items: items, total: total, limit: effectiveLimit, offset: offset)
    }

    func page(
        colorName: String,
        scope: AnnotationScope = .activeRaw,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> Page<EnrichedAnnotation> {
        let effectiveLimit = try resolvedPageLimit(limit, default: 50, offset: offset)
        let color = try AnnotationColor(name: colorName)
        let total = try count(scope: scope, style: color.rawValue, capability: .annotationByStyle)
        let items = try byStyle(color.rawValue, scope: scope, limit: effectiveLimit, offset: offset)
        return Page(items: items, total: total, limit: effectiveLimit, offset: offset)
    }

    func getByLocalPK(_ localPK: Int64, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        try query(.localPK(localPK), capability: .annotationUserBase, scope: scope, limit: 1, offset: 0).first
    }

    func getByUUID(_ uuid: String, scope: AnnotationScope = .user) throws -> [EnrichedAnnotation] {
        try query(.uuid(uuid), capability: .annotationByUUID, scope: scope, limit: nil, offset: 0)
    }

    func getUniqueByUUID(_ uuid: String, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        _ = try AppleBooksSchema.inspect(.annotationByUUID, on: annotationConnection)
        let statement = try annotationConnection.prepare("""
            SELECT \(AppleBooksSchema.Annotation.localPK), \(AppleBooksSchema.Annotation.uuid)
            FROM \(AppleBooksTable.annotations.rawValue)
            WHERE \(Self.scopePredicate(scope))
              AND \(AppleBooksSchema.Annotation.uuid) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Annotation.localPK)
            LIMIT 2
            """)
        try statement.bind(uuid, at: 1)
        guard try statement.step() else { return nil }
        let first = try SQLiteRow(statement: statement)
        guard let localPK = try first.int64(AppleBooksSchema.Annotation.localPK),
              try first.text(AppleBooksSchema.Annotation.uuid) == uuid else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Annotation.localPK)
        }
        if try statement.step() {
            throw StableIdentityError.ambiguousAnnotationUUID
        }
        return try getByLocalPK(localPK, scope: scope)
    }

    func byAssetID(
        _ assetID: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try query(.assetID(assetID), capability: .annotationByAssetID, scope: scope, limit: limit, offset: offset)
    }

    func byStyle(
        _ style: Int64,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        try query(.style(style), capability: .annotationByStyle, scope: scope, limit: limit, offset: offset)
    }

    func byColorName(
        _ name: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        let color = try AnnotationColor(name: name)
        return try byStyle(color.rawValue, scope: scope, limit: limit, offset: offset)
    }

    func searchHighlightedText(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try query(
            .highlightedText(text),
            capability: .annotationHighlightedText,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style
        )
    }

    func searchNote(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try query(
            .note(text),
            capability: .annotationNote,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style
        )
    }

    func searchText(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try query(
            .fullText(text),
            capability: .annotationFullText,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style
        )
    }

    func recentlyModified() throws -> [EnrichedAnnotation] {
        try query(
            .none,
            capability: .annotationByModificationDate,
            scope: .activeRaw,
            limit: 10,
            offset: 0,
            order: .modificationRecent
        )
    }

    func recentlyCreated(limit: Int? = 10, offset: Int = 0) throws -> [EnrichedAnnotation] {
        try query(
            .none,
            capability: .annotationByCreationDate,
            scope: .user,
            limit: limit,
            offset: offset,
            order: .creationRecent
        )
    }

    func created(
        lowerInclusive: Date? = nil,
        upperExclusive: Date? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [EnrichedAnnotation] {
        if let lowerInclusive, let upperExclusive, lowerInclusive >= upperExclusive {
            throw AnnotationQueryInputError.invalidDateRange
        }
        let lowerSeconds = CoreDataTime.seconds(from: lowerInclusive)
        let upperSeconds = CoreDataTime.seconds(from: upperExclusive)
        guard lowerInclusive == nil || lowerSeconds != nil,
              upperExclusive == nil || upperSeconds != nil else {
            throw AnnotationQueryInputError.invalidDateRange
        }
        return try query(
            .creationRange(lower: lowerSeconds, upper: upperSeconds),
            capability: .annotationByCreationDate,
            scope: scope,
            limit: limit,
            offset: offset
        )
    }

    func semanticList(
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try semanticQuery(
            .none,
            capability: .annotationUserBase,
            scope: scope,
            limit: limit,
            offset: offset,
            textMode: .preview
        )
    }

    func semanticGetByLocalPK(
        _ localPK: Int64,
        scope: AnnotationScope = .user
    ) throws -> SemanticAnnotation? {
        try semanticQuery(
            .localPK(localPK),
            capability: .annotationUserBase,
            scope: scope,
            limit: 1,
            offset: 0,
            textMode: .detail
        ).first
    }

    func semanticGetUniqueByUUID(
        _ uuid: String,
        scope: AnnotationScope = .user
    ) throws -> SemanticAnnotation? {
        _ = try AppleBooksSchema.inspect(.annotationByUUID, on: annotationConnection)
        let statement = try annotationConnection.prepare("""
            SELECT \(AppleBooksSchema.Annotation.localPK)
            FROM \(AppleBooksTable.annotations.rawValue)
            WHERE \(Self.scopePredicate(scope))
              AND \(AppleBooksSchema.Annotation.uuid) = ? COLLATE BINARY
            ORDER BY \(AppleBooksSchema.Annotation.localPK)
            LIMIT 2
            """)
        try statement.bind(uuid, at: 1)
        guard try statement.step(),
              let localPK = try SQLiteRow(statement: statement).int64(AppleBooksSchema.Annotation.localPK) else {
            return nil
        }
        if try statement.step() { throw StableIdentityError.ambiguousAnnotationUUID }
        return try semanticGetByLocalPK(localPK, scope: scope)
    }

    func semanticByAssetID(
        _ assetID: String,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try semanticQuery(
            .assetID(assetID),
            capability: .annotationByAssetID,
            scope: scope,
            limit: limit,
            offset: offset,
            textMode: .preview
        )
    }

    func semanticSearchHighlightedText(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try semanticQuery(
            .highlightedText(text),
            capability: .annotationHighlightedText,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style,
            textMode: .preview
        )
    }

    func semanticSearchNote(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try semanticQuery(
            .note(text),
            capability: .annotationNote,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style,
            textMode: .preview
        )
    }

    func semanticSearchText(
        _ text: String,
        colorName: String? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        let style = try colorName.map { try AnnotationColor(name: $0).rawValue }
        return try semanticQuery(
            .fullText(text),
            capability: .annotationFullText,
            scope: scope,
            limit: limit,
            offset: offset,
            styleConstraint: style,
            textMode: .preview
        )
    }

    func semanticRecentlyModified() throws -> [SemanticAnnotation] {
        try semanticQuery(
            .none,
            capability: .annotationByModificationDate,
            scope: .activeRaw,
            limit: 10,
            offset: 0,
            order: .modificationRecent,
            textMode: .preview
        )
    }

    func semanticRecentlyCreated(
        limit: Int? = 10,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        try semanticQuery(
            .none,
            capability: .annotationByCreationDate,
            scope: .user,
            limit: limit,
            offset: offset,
            order: .creationRecent,
            textMode: .preview
        )
    }

    func semanticCreated(
        lowerInclusive: Date? = nil,
        upperExclusive: Date? = nil,
        scope: AnnotationScope = .user,
        limit: Int? = nil,
        offset: Int = 0
    ) throws -> [SemanticAnnotation] {
        if let lowerInclusive, let upperExclusive, lowerInclusive >= upperExclusive {
            throw AnnotationQueryInputError.invalidDateRange
        }
        let lowerSeconds = CoreDataTime.seconds(from: lowerInclusive)
        let upperSeconds = CoreDataTime.seconds(from: upperExclusive)
        guard lowerInclusive == nil || lowerSeconds != nil,
              upperExclusive == nil || upperSeconds != nil else {
            throw AnnotationQueryInputError.invalidDateRange
        }
        return try semanticQuery(
            .creationRange(lower: lowerSeconds, upper: upperSeconds),
            capability: .annotationByCreationDate,
            scope: scope,
            limit: limit,
            offset: offset,
            textMode: .preview
        )
    }

    private struct SemanticAnnotationRow {
        let localPK: Int64
        let uuid: String?
        let rawAssetID: String?
        let sourceIdentityUnavailable: Bool
        let isDeleted: Bool?
        let isUnderline: Bool?
        let style: Int64?
        let type: Int64?
        let createdAt: Date?
        let modifiedAt: Date?
        let representativeText: String?
        let selectedText: String?
        let note: String?
        let rawCFI: String?
        let chapterHint: String?
        let physicalLocation: Int64?
        let rangeStart: Int64?
        let rangeEnd: Int64?
        let byteTruncatedFields: [String]

        func annotation(source: SemanticAnnotationSource) -> SemanticAnnotation {
            SemanticAnnotation(
                localPK: localPK,
                uuid: uuid,
                rawAssetID: rawAssetID,
                isDeleted: isDeleted,
                isUnderline: isUnderline,
                style: style,
                type: type,
                createdAt: createdAt,
                modifiedAt: modifiedAt,
                representativeText: representativeText,
                selectedText: selectedText,
                note: note,
                rawCFI: rawCFI,
                chapterHint: chapterHint,
                physicalLocation: physicalLocation,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                source: source,
                byteTruncatedFields: byteTruncatedFields
            )
        }
    }

    private func semanticQuery(
        _ filter: Filter,
        capability: SchemaCapability,
        scope: AnnotationScope,
        limit: Int?,
        offset: Int,
        styleConstraint: Int64? = nil,
        order queryOrder: QueryOrder = .standard,
        textMode: SemanticTextMode
    ) throws -> [SemanticAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        if styleConstraint != nil {
            _ = try AppleBooksSchema.inspect(.annotationByStyle, on: annotationConnection)
        }
        let schema = try AppleBooksSchema.inspect(capability, on: annotationConnection)
        let projection = semanticProjection(schema: schema, textMode: textMode)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue)"
        sql += " WHERE \(Self.scopePredicate(scope))"
        appendSemanticFilter(filter, styleConstraint: styleConstraint, to: &sql)
        appendSemanticOrder(queryOrder, schema: schema, to: &sql)
        if limit != nil {
            sql += " LIMIT ? OFFSET ?"
        } else if offset > 0 {
            sql += " LIMIT -1 OFFSET ?"
        }

        let statement = try annotationConnection.prepare(sql)
        var index = try bindSemanticFilter(filter, to: statement, startingAt: 1)
        if let styleConstraint {
            try statement.bind(styleConstraint, at: index)
            index += 1
        }
        if let limit {
            try statement.bind(Int64(limit), at: index)
            try statement.bind(Int64(offset), at: index + 1)
        } else if offset > 0 {
            try statement.bind(Int64(offset), at: index)
        }

        var results: [SemanticAnnotation] = []
        var batch: [SemanticAnnotationRow] = []
        batch.reserveCapacity(AnnotationSourceClassifier.maximumBatch)
        func flush() throws {
            guard batch.isEmpty == false else { return }
            results.append(contentsOf: try enrichSemantic(batch))
            batch.removeAll(keepingCapacity: true)
        }
        while try statement.step() {
            batch.append(try decodeSemantic(
                SQLiteRow(statement: statement),
                schema: schema,
                textMode: textMode
            ))
            if batch.count == AnnotationSourceClassifier.maximumBatch {
                try flush()
            }
        }
        try flush()
        return results
    }

    private func semanticProjection(
        schema: SchemaAvailability,
        textMode: SemanticTextMode
    ) -> [String] {
        var projection = [AppleBooksSchema.Annotation.localPK]
        if schema.contains(AppleBooksSchema.Annotation.uuid) {
            projection += SQLiteTextProjection.exact(
                AppleBooksSchema.Annotation.uuid,
                alias: "annotationUUID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        if schema.contains(AppleBooksSchema.Annotation.assetID) {
            projection += SQLiteTextProjection.exact(
                AppleBooksSchema.Annotation.assetID,
                alias: "annotationAssetID",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            )
        }
        for column in [
            AppleBooksSchema.Annotation.isDeleted,
            AppleBooksSchema.Annotation.isUnderline,
            AppleBooksSchema.Annotation.style,
            AppleBooksSchema.Annotation.type,
            AppleBooksSchema.Annotation.creationDate,
            AppleBooksSchema.Annotation.modificationDate,
            AppleBooksSchema.Annotation.physicalLocation,
            AppleBooksSchema.Annotation.rangeStart,
            AppleBooksSchema.Annotation.rangeEnd,
        ] where schema.contains(column) {
            projection.append(column)
        }
        if schema.contains(AppleBooksSchema.Annotation.representativeText) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Annotation.representativeText,
                alias: "annotationRepresentativeText",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.preview
            )
        }
        if schema.contains(AppleBooksSchema.Annotation.selectedText) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Annotation.selectedText,
                alias: "annotationSelectedText",
                maximumUTF8Bytes: textMode.selectedTextBudget
            )
        }
        if schema.contains(AppleBooksSchema.Annotation.note) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Annotation.note,
                alias: "annotationNote",
                maximumUTF8Bytes: textMode.noteBudget
            )
        }
        if schema.contains(AppleBooksSchema.Annotation.location) {
            projection += SQLiteTextProjection.exact(
                AppleBooksSchema.Annotation.location,
                alias: "annotationLocation",
                maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
            )
        }
        if schema.contains(AppleBooksSchema.Annotation.chapterHint) {
            projection += SQLiteTextProjection.bounded(
                AppleBooksSchema.Annotation.chapterHint,
                alias: "annotationChapterHint",
                maximumUTF8Bytes: SQLiteSemanticTextBudget.metadata
            )
        }
        return projection
    }

    private func decodeSemantic(
        _ row: SQLiteRow,
        schema: SchemaAvailability,
        textMode: SemanticTextMode
    ) throws -> SemanticAnnotationRow {
        guard let localPK = try row.int64(AppleBooksSchema.Annotation.localPK) else {
            throw QueryDecodingError.nullRequiredColumn(AppleBooksSchema.Annotation.localPK)
        }

        let uuid: String?
        if schema.contains(AppleBooksSchema.Annotation.uuid) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "annotationUUID",
                column: AppleBooksSchema.Annotation.uuid,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value): uuid = value
            case .value, .null, .oversized: uuid = nil
            }
        } else {
            uuid = nil
        }

        let rawAssetID: String?
        let sourceIdentityUnavailable: Bool
        if schema.contains(AppleBooksSchema.Annotation.assetID) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "annotationAssetID",
                column: AppleBooksSchema.Annotation.assetID,
                maximumUTF8Bytes: SQLiteSemanticTextBudget.stableIdentity
            ) {
            case .null:
                rawAssetID = nil
                sourceIdentityUnavailable = false
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value):
                rawAssetID = value
                sourceIdentityUnavailable = false
            case .value, .oversized:
                rawAssetID = nil
                sourceIdentityUnavailable = true
            }
        } else {
            rawAssetID = nil
            sourceIdentityUnavailable = false
        }

        func int64(_ column: String) throws -> Int64? {
            schema.contains(column) ? try row.int64(column) : nil
        }
        func date(_ column: String) throws -> Date? {
            guard schema.contains(column) else { return nil }
            return CoreDataTime.date(from: try row.double(column))
        }
        func bounded(
            _ column: String,
            alias: String,
            budget: Int
        ) throws -> BoundedSQLiteText {
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

        let representative = try bounded(
            AppleBooksSchema.Annotation.representativeText,
            alias: "annotationRepresentativeText",
            budget: SQLiteSemanticTextBudget.preview
        )
        let selected = try bounded(
            AppleBooksSchema.Annotation.selectedText,
            alias: "annotationSelectedText",
            budget: textMode.selectedTextBudget
        )
        let note = try bounded(
            AppleBooksSchema.Annotation.note,
            alias: "annotationNote",
            budget: textMode.noteBudget
        )
        let chapterHint = try bounded(
            AppleBooksSchema.Annotation.chapterHint,
            alias: "annotationChapterHint",
            budget: SQLiteSemanticTextBudget.metadata
        )

        let rawCFI: String?
        if schema.contains(AppleBooksSchema.Annotation.location) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "annotationLocation",
                column: AppleBooksSchema.Annotation.location,
                maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
            ) {
            case let .value(value): rawCFI = value
            case .null, .oversized: rawCFI = nil
            }
        } else {
            rawCFI = nil
        }

        var truncated: [String] = []
        for (field, value) in [
            ("representativeText", representative),
            ("selectedText", selected),
            ("note", note),
            ("chapterHint", chapterHint),
        ] where value.wasByteTruncated {
            truncated.append(field)
        }

        return SemanticAnnotationRow(
            localPK: localPK,
            uuid: uuid,
            rawAssetID: rawAssetID,
            sourceIdentityUnavailable: sourceIdentityUnavailable,
            isDeleted: try int64(AppleBooksSchema.Annotation.isDeleted).map { $0 != 0 },
            isUnderline: try int64(AppleBooksSchema.Annotation.isUnderline).map { $0 != 0 },
            style: try int64(AppleBooksSchema.Annotation.style),
            type: try int64(AppleBooksSchema.Annotation.type),
            createdAt: try date(AppleBooksSchema.Annotation.creationDate),
            modifiedAt: try date(AppleBooksSchema.Annotation.modificationDate),
            representativeText: representative.value,
            selectedText: selected.value,
            note: note.value,
            rawCFI: rawCFI,
            chapterHint: chapterHint.value,
            physicalLocation: try int64(AppleBooksSchema.Annotation.physicalLocation),
            rangeStart: try int64(AppleBooksSchema.Annotation.rangeStart),
            rangeEnd: try int64(AppleBooksSchema.Annotation.rangeEnd),
            byteTruncatedFields: truncated
        )
    }

    private func enrichSemantic(_ rows: [SemanticAnnotationRow]) throws -> [SemanticAnnotation] {
        precondition(rows.count <= AnnotationSourceClassifier.maximumBatch)
        let classifier = AnnotationSourceClassifier(
            bookQueries: bookQueries,
            historicalAssets: historicalAssets
        )
        let eligibleAssetIDs = rows.compactMap { row in
            row.sourceIdentityUnavailable ? nil : row.rawAssetID
        }
        let classified = try classifier.classifyEligible(eligibleAssetIDs)
        let currentPKs = Array(Set(classified.values.compactMap { state -> Int64? in
            guard case let .current(localPK) = state else { return nil }
            return localPK
        }))
        let currentBooks = try bookQueries.semanticSummaries(localPKs: currentPKs)

        return rows.map { row in
            let source: SemanticAnnotationSource
            if row.sourceIdentityUnavailable {
                source = SemanticAnnotationSource(kind: .identityUnavailable)
            } else if let assetID = row.rawAssetID {
                switch classified[assetID] ?? .schemaUnavailable {
                case let .current(localPK):
                    let book = currentBooks[localPK]
                    source = SemanticAnnotationSource(
                        kind: .currentLibrary,
                        bookLocalPK: localPK,
                        bookAssetID: book?.assetID ?? assetID,
                        title: book?.title,
                        author: book?.author,
                        byteTruncatedFields: book?.byteTruncatedFields ?? []
                    )
                case .historical:
                    let metadata = historicalAssets.metadata(for: assetID)
                    source = SemanticAnnotationSource(
                        kind: .historicalInferred,
                        title: metadata?.title,
                        author: metadata?.author
                    )
                case .unmapped:
                    source = SemanticAnnotationSource(kind: .unmapped)
                case .ambiguousCurrent:
                    source = SemanticAnnotationSource(kind: .ambiguousCurrent)
                case .identityUnavailable:
                    source = SemanticAnnotationSource(kind: .identityUnavailable)
                case .schemaUnavailable:
                    source = SemanticAnnotationSource(kind: .schemaUnavailable)
                }
            } else {
                source = SemanticAnnotationSource(kind: .unmapped)
            }
            return row.annotation(source: source)
        }
    }

    private func appendSemanticFilter(
        _ filter: Filter,
        styleConstraint: Int64?,
        to sql: inout String
    ) {
        switch filter {
        case .none:
            break
        case .localPK:
            sql += " AND \(AppleBooksSchema.Annotation.localPK) = ?"
        case .uuid:
            sql += " AND \(AppleBooksSchema.Annotation.uuid) = ? COLLATE BINARY"
        case .assetID:
            sql += " AND \(AppleBooksSchema.Annotation.assetID) = ? COLLATE BINARY"
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
            let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
            if lower != nil { sql += " AND \(creationDate) >= ?" }
            if upper != nil { sql += " AND \(creationDate) < ?" }
        }
        if styleConstraint != nil {
            sql += " AND \(AppleBooksSchema.Annotation.style) = ?"
        }
    }

    private func appendSemanticOrder(
        _ queryOrder: QueryOrder,
        schema: SchemaAvailability,
        to sql: inout String
    ) {
        let order: [String]
        switch queryOrder {
        case .standard:
            var standard: [String] = []
            if schema.contains(AppleBooksSchema.Annotation.modificationDate) {
                let modificationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
                standard += ["\(modificationDate) IS NULL", "\(modificationDate) DESC"]
            }
            if schema.contains(AppleBooksSchema.Annotation.creationDate) {
                let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
                standard += ["\(creationDate) IS NULL", "\(creationDate) DESC"]
            }
            standard.append("\(AppleBooksSchema.Annotation.localPK) DESC")
            order = standard
        case .modificationRecent:
            let modificationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
            order = [
                "\(modificationDate) IS NULL",
                "\(modificationDate) DESC",
                "\(AppleBooksSchema.Annotation.localPK) DESC",
            ]
        case .creationRecent:
            let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
            order = [
                "\(creationDate) IS NULL",
                "\(creationDate) DESC",
                "\(AppleBooksSchema.Annotation.localPK) DESC",
            ]
        }
        sql += " ORDER BY \(order.joined(separator: ", "))"
    }

    private func bindSemanticFilter(
        _ filter: Filter,
        to statement: SQLiteStatement,
        startingAt startIndex: Int32
    ) throws -> Int32 {
        var index = startIndex
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
        return index
    }

    private static func scopePredicate(_ scope: AnnotationScope) -> String {
        var predicate = "\(AppleBooksSchema.Annotation.isDeleted) = 0"
        if scope == .user {
            predicate += " AND \(AppleBooksSchema.Annotation.type) != 3"
        }
        return predicate
    }

    private func query(
        _ filter: Filter,
        capability: SchemaCapability,
        scope: AnnotationScope,
        limit: Int?,
        offset: Int,
        styleConstraint: Int64? = nil,
        order queryOrder: QueryOrder = .standard
    ) throws -> [EnrichedAnnotation] {
        try validatePagination(limit: limit, offset: offset)
        if styleConstraint != nil {
            _ = try AppleBooksSchema.inspect(.annotationByStyle, on: annotationConnection)
        }
        let schema = try AppleBooksSchema.inspect(capability, on: annotationConnection)
        let projection = [AppleBooksSchema.Annotation.localPK]
            + AppleBooksSchema.Annotation.allProjection.filter(schema.contains)
        var sql = "SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue)"
        sql += " WHERE \(Self.scopePredicate(scope))"

        switch filter {
        case .none:
            break
        case .localPK:
            sql += " AND \(AppleBooksSchema.Annotation.localPK) = ?"
        case .uuid:
            sql += " AND \(AppleBooksSchema.Annotation.uuid) = ? COLLATE BINARY"
        case .assetID:
            sql += " AND \(AppleBooksSchema.Annotation.assetID) = ? COLLATE BINARY"
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
            let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
            if lower != nil {
                sql += " AND \(creationDate) >= ?"
            }
            if upper != nil {
                sql += " AND \(creationDate) < ?"
            }
        }
        if styleConstraint != nil {
            sql += " AND \(AppleBooksSchema.Annotation.style) = ?"
        }

        let order: [String]
        switch queryOrder {
        case .standard:
            var standard: [String] = []
            if schema.contains(AppleBooksSchema.Annotation.modificationDate) {
                let modificationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
                standard += [
                    "\(modificationDate) IS NULL",
                    "\(modificationDate) DESC",
                ]
            }
            if schema.contains(AppleBooksSchema.Annotation.creationDate) {
                let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
                standard += [
                    "\(creationDate) IS NULL",
                    "\(creationDate) DESC",
                ]
            }
            standard.append("\(AppleBooksSchema.Annotation.localPK) DESC")
            order = standard
        case .modificationRecent:
            let modificationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.modificationDate)
            order = [
                "\(modificationDate) IS NULL",
                "\(modificationDate) DESC",
                "\(AppleBooksSchema.Annotation.localPK) DESC",
            ]
        case .creationRecent:
            let creationDate = SemanticSQLiteReal.dateSQL(AppleBooksSchema.Annotation.creationDate)
            order = [
                "\(creationDate) IS NULL",
                "\(creationDate) DESC",
                "\(AppleBooksSchema.Annotation.localPK) DESC",
            ]
        }
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
        if let styleConstraint {
            try statement.bind(styleConstraint, at: index)
            index += 1
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

    private func count(
        scope: AnnotationScope,
        style: Int64?,
        capability: SchemaCapability
    ) throws -> Int {
        _ = try AppleBooksSchema.inspect(capability, on: annotationConnection)
        var sql = "SELECT COUNT(*) AS count FROM \(AppleBooksTable.annotations.rawValue) WHERE \(Self.scopePredicate(scope))"
        if style != nil {
            sql += " AND \(AppleBooksSchema.Annotation.style) = ?"
        }
        let statement = try annotationConnection.prepare(sql)
        if let style {
            try statement.bind(style, at: 1)
        }
        guard try statement.step(),
              let value = try SQLiteRow(statement: statement).int64("count"),
              value >= 0 else {
            throw QueryDecodingError.nullRequiredColumn("count")
        }
        return Int(value)
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
        EnrichedAnnotation(annotation: annotation, source: try source(for: annotation.rawAssetID))
    }

    private func source(for assetID: String?) throws -> AnnotationSource {
        guard let assetID else { return .unmapped }

        do {
            let matches = try bookQueries.getByAssetID(assetID)
            if matches.count == 1, let book = matches.first {
                return .currentLibrary(book)
            }
        } catch is SchemaCompatibilityError {
            // ponytail: schema drift only disables current-library enrichment; canonical AEAnnotation rows remain authoritative.
        }

        if let metadata = historicalAssets.metadata(for: assetID) {
            return .historicalInferred(metadata)
        }
        return .unmapped
    }
}

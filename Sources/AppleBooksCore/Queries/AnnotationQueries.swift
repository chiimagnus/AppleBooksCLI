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
    let configuration: AppleBooksConfiguration
    let configurationFileURL: URL

    init(
        annotationConnection: SQLiteConnection,
        bookQueries: BookQueries,
        historicalAssets: HistoricalAssets,
        configuration: AppleBooksConfiguration = .empty,
        configurationFileURL: URL = AppleBooksConfiguration.defaultFileURL
    ) {
        self.annotationConnection = annotationConnection
        self.bookQueries = bookQueries
        self.historicalAssets = historicalAssets
        self.configuration = configuration
        self.configurationFileURL = configurationFileURL
    }

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

    func semanticPage(
        _ request: AnnotationQueryRequest,
        instrumentation: AnnotationQueryInstrumentation? = nil
    ) throws -> CursorPage<SemanticAnnotation> {
        let limit = try resolvedCursorPageLimit(request.limit)
        let schema = try AppleBooksSchema.inspect(.annotationUserBase, on: annotationConnection)
        try validateQuerySchema(request, schema: schema)
        let resolvedBook = try resolveBook(request.book)
        let readingContext = request.order == .reading
            ? try resolveReadingContext(bookLocalPK: resolvedBook.currentBookLocalPK)
            : nil
        let beforeGeneration: CursorGeneration
        if let readingContext {
            beforeGeneration = try annotationCursorGeneration(readingContext: readingContext.generation)
        } else {
            beforeGeneration = try annotationCursorGeneration(readingContext: nil)
        }
        let fingerprint = try annotationQueryFingerprint(request)
        let session = try CursorPaginationSession(
            cursor: request.cursor,
            fingerprint: fingerprint,
            generation: beforeGeneration
        )
        let anchorPK = try annotationAnchorPK(session.locator)

        let candidatePKs: [Int64]
        switch request.order {
        case .created, .modified:
            candidatePKs = try orderedCandidatePKs(
                request: request,
                resolvedAssetID: resolvedBook.assetID,
                schema: schema,
                anchorPK: anchorPK,
                limit: limit + 1
            )
        case .reading:
            guard let readingContext else { throw CursorPaginationError.internalContractFailure }
            let anchor = try anchorPK.map {
                try readingAnchor(
                    localPK: $0,
                    request: request,
                    resolvedAssetID: resolvedBook.assetID,
                    schema: schema,
                    chapterOrder: readingContext.chapterOrder
                )
            }
            candidatePKs = try readingCandidatePKs(
                request: request,
                resolvedAssetID: resolvedBook.assetID,
                schema: schema,
                chapterOrder: readingContext.chapterOrder,
                anchor: anchor,
                limit: limit + 1,
                instrumentation: instrumentation
            )
        }

        let hasMore = candidatePKs.count > limit
        let pagePKs = Array(candidatePKs.prefix(limit))
        let items = try semanticRows(
            localPKs: pagePKs,
            schema: schema,
            instrumentation: instrumentation
        )
        let afterGeneration: CursorGeneration
        if request.order == .reading {
            let afterContext = try resolveReadingContext(bookLocalPK: resolvedBook.currentBookLocalPK)
            afterGeneration = try annotationCursorGeneration(readingContext: afterContext.generation)
        } else {
            afterGeneration = try annotationCursorGeneration(readingContext: nil)
        }
        let nextCursor = try session.nextCursor(
            after: afterGeneration,
            hasMore: hasMore,
            locator: hasMore ? try pagePKs.last.map(CursorLocator.rowID) : nil
        )
        return CursorPage(items: items, nextCursor: nextCursor, hasMore: hasMore)
    }

    private struct ResolvedBookFilter {
        let assetID: String?
        let currentBookLocalPK: Int64?
    }

    private struct ReadingContext {
        let chapterOrder: [String: Int]
        let generation: CursorGenerationComponent
    }

    private struct ReadingCandidate {
        let localPK: Int64
        let key: EPUBAnnotationReadingKey
    }

    private func resolveBook(_ selector: AnnotationQueryBookSelector?) throws -> ResolvedBookFilter {
        guard let selector else { return ResolvedBookFilter(assetID: nil, currentBookLocalPK: nil) }
        switch selector {
        case let .assetID(assetID):
            do {
                let multiplicity = try bookQueries.identityMultiplicity(assetIDs: [assetID])[assetID]
                if let multiplicity, multiplicity.count > 1 {
                    throw StableIdentityError.ambiguousBookAssetID
                }
                return ResolvedBookFilter(assetID: assetID, currentBookLocalPK: multiplicity?.uniqueLocalPK)
            } catch is SchemaCompatibilityError {
                return ResolvedBookFilter(assetID: assetID, currentBookLocalPK: nil)
            }
        case let .localPK(localPK):
            return ResolvedBookFilter(
                assetID: try bookQueries.annotationAssetID(localPK: localPK),
                currentBookLocalPK: localPK
            )
        }
    }

    private func resolveReadingContext(bookLocalPK: Int64?) throws -> ReadingContext {
        guard let bookLocalPK else {
            return ReadingContext(
                chapterOrder: [:],
                generation: try .synthetic(label: "reading-context", value: "structural-only")
            )
        }
        do {
            guard let target = try bookQueries.resourceTarget(localPK: bookLocalPK), target.path != nil else {
                throw ContentError.bookPathUnavailable
            }
            let selected = try EPUBSourceResolver.resolve(for: target, configuration: configuration).requireReader()
            let context = try BookContent(reader: selected.reader).annotationReadingContext()
            return ReadingContext(chapterOrder: context.chapterOrder, generation: context.generation)
        } catch let error as CursorPaginationError {
            throw error
        } catch {
            return ReadingContext(
                chapterOrder: [:],
                generation: try .synthetic(label: "reading-context", value: "structural-only")
            )
        }
    }

    private func annotationCursorGeneration(readingContext: CursorGenerationComponent?) throws -> CursorGeneration {
        var components: [CursorGenerationComponent] = [
            try .sqlite(label: "annotations", databaseURL: annotationConnection.databaseURL),
            try .sqlite(label: "library", databaseURL: bookQueries.connection.databaseURL),
            try .regularFile(label: "config", url: configurationFileURL, optional: true),
        ]
        if let readingContext { components.append(readingContext) }
        return try CursorGeneration.compose(components)
    }

    private func annotationQueryFingerprint(_ request: AnnotationQueryRequest) throws -> CursorQueryFingerprint {
        var fields = [
            CursorFingerprintField("order.version", .unsigned(1)),
            CursorFingerprintField("order.kind", .string(request.order.rawValue)),
            CursorFingerprintField("text.field", .string(request.textField.rawValue)),
            CursorFingerprintField("text.value", request.text.map(CursorFingerprintValue.string) ?? .null),
            CursorFingerprintField("created.after", fingerprintDate(request.createdAfter)),
            CursorFingerprintField("created.before", fingerprintDate(request.createdBefore)),
            CursorFingerprintField("modified.after", fingerprintDate(request.modifiedAfter)),
            CursorFingerprintField("modified.before", fingerprintDate(request.modifiedBefore)),
            CursorFingerprintField("color", request.color.map { .signed($0.rawValue) } ?? .null),
            CursorFingerprintField("underline", request.underline.map(CursorFingerprintValue.bool) ?? .null),
            CursorFingerprintField("has-highlight", request.hasHighlight.map(CursorFingerprintValue.bool) ?? .null),
            CursorFingerprintField("has-note", request.hasNote.map(CursorFingerprintValue.bool) ?? .null),
        ]
        switch request.book {
        case nil:
            fields += [
                CursorFingerprintField("book.kind", .null),
                CursorFingerprintField("book.value", .null),
            ]
        case let .assetID(value):
            fields += [
                CursorFingerprintField("book.kind", .string("asset")),
                CursorFingerprintField("book.value", .string(value)),
            ]
        case let .localPK(value):
            fields += [
                CursorFingerprintField("book.kind", .string("pk")),
                CursorFingerprintField("book.value", .signed(value)),
            ]
        }
        return try CursorQueryFingerprint.make(kind: "annotations.list", fields: fields)
    }

    private func fingerprintDate(_ value: Date?) -> CursorFingerprintValue {
        guard let seconds = CoreDataTime.seconds(from: value) else { return .null }
        return .unsigned(seconds.bitPattern)
    }

    private func annotationAnchorPK(_ locator: CursorLocator?) throws -> Int64? {
        guard let locator else { return nil }
        guard locator.words.count == 1 else { throw CursorPaginationError.invalidCursor }
        return Int64(bitPattern: locator.words[0])
    }

    private func validateQuerySchema(_ request: AnnotationQueryRequest, schema: SchemaAvailability) throws {
        var required = Set<String>()
        if request.book != nil { required.insert(AppleBooksSchema.Annotation.assetID) }
        if request.createdAfter != nil || request.createdBefore != nil || request.order == .created || request.order == .reading {
            required.insert(AppleBooksSchema.Annotation.creationDate)
        }
        if request.modifiedAfter != nil || request.modifiedBefore != nil || request.order == .modified {
            required.insert(AppleBooksSchema.Annotation.modificationDate)
        }
        if request.order == .modified { required.insert(AppleBooksSchema.Annotation.creationDate) }
        if request.color != nil { required.insert(AppleBooksSchema.Annotation.style) }
        if request.text != nil {
            switch request.textField {
            case .all:
                required.formUnion([
                    AppleBooksSchema.Annotation.selectedText,
                    AppleBooksSchema.Annotation.representativeText,
                    AppleBooksSchema.Annotation.note,
                ])
            case .highlight:
                required.insert(AppleBooksSchema.Annotation.selectedText)
            case .note:
                required.insert(AppleBooksSchema.Annotation.note)
            }
        }
        let missing = required.filter { schema.contains($0) == false }.sorted()
        if missing.isEmpty == false {
            throw SchemaCompatibilityError.missingRequiredColumns(table: .annotations, columns: missing)
        }
    }

    private func queryPredicates(
        _ request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        schema: SchemaAvailability,
        alias: String
    ) -> [String] {
        let column: (String) -> String = { "\(alias).\($0)" }
        var predicates = [
            "\(column(AppleBooksSchema.Annotation.isDeleted)) = 0",
            "\(column(AppleBooksSchema.Annotation.type)) != 3",
        ]
        if request.book != nil {
            if resolvedAssetID != nil {
                predicates.append("\(column(AppleBooksSchema.Annotation.assetID)) = ? COLLATE BINARY")
            } else {
                predicates.append("0")
            }
        }
        if let text = request.text, text.isEmpty == false {
            switch request.textField {
            case .all:
                predicates.append("(\(column(AppleBooksSchema.Annotation.selectedText)) LIKE ? ESCAPE '\\' COLLATE NOCASE OR \(column(AppleBooksSchema.Annotation.representativeText)) LIKE ? ESCAPE '\\' COLLATE NOCASE OR \(column(AppleBooksSchema.Annotation.note)) LIKE ? ESCAPE '\\' COLLATE NOCASE)")
            case .highlight:
                predicates.append("\(column(AppleBooksSchema.Annotation.selectedText)) LIKE ? ESCAPE '\\' COLLATE NOCASE")
            case .note:
                predicates.append("\(column(AppleBooksSchema.Annotation.note)) LIKE ? ESCAPE '\\' COLLATE NOCASE")
            }
        }
        let created = SemanticSQLiteReal.dateSQL(column(AppleBooksSchema.Annotation.creationDate))
        if request.createdAfter != nil { predicates.append("\(created) >= ?") }
        if request.createdBefore != nil { predicates.append("\(created) < ?") }
        let modified = SemanticSQLiteReal.dateSQL(column(AppleBooksSchema.Annotation.modificationDate))
        if request.modifiedAfter != nil { predicates.append("\(modified) >= ?") }
        if request.modifiedBefore != nil { predicates.append("\(modified) < ?") }
        if request.color != nil { predicates.append("\(column(AppleBooksSchema.Annotation.style)) = ?") }
        if let underline = request.underline {
            let evidence = schema.contains(AppleBooksSchema.Annotation.isUnderline)
                ? AnnotationContentSemantics.underlineSQL(column(AppleBooksSchema.Annotation.isUnderline))
                : "0"
            predicates.append(underline ? evidence : "NOT (\(evidence))")
        }
        if let hasHighlight = request.hasHighlight {
            let evidence = schema.contains(AppleBooksSchema.Annotation.selectedText)
                ? AnnotationContentSemantics.hasContentSQL(column(AppleBooksSchema.Annotation.selectedText))
                : "0"
            predicates.append(hasHighlight ? evidence : "NOT (\(evidence))")
        }
        if let hasNote = request.hasNote {
            let evidence = schema.contains(AppleBooksSchema.Annotation.note)
                ? AnnotationContentSemantics.hasContentSQL(column(AppleBooksSchema.Annotation.note))
                : "0"
            predicates.append(hasNote ? evidence : "NOT (\(evidence))")
        }
        return predicates
    }

    private func bindQuery(
        _ request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        to statement: SQLiteStatement,
        startingAt startIndex: Int32
    ) throws -> Int32 {
        var index = startIndex
        if request.book != nil, let resolvedAssetID {
            try statement.bind(resolvedAssetID, at: index)
            index += 1
        }
        if let text = request.text {
            let pattern = literalContainsPattern(text)
            switch request.textField {
            case .all:
                for offset in 0..<3 { try statement.bind(pattern, at: index + Int32(offset)) }
                index += 3
            case .highlight, .note:
                try statement.bind(pattern, at: index)
                index += 1
            }
        }
        for date in [request.createdAfter, request.createdBefore, request.modifiedAfter, request.modifiedBefore] {
            if let date, let seconds = CoreDataTime.seconds(from: date) {
                try statement.bind(seconds, at: index)
                index += 1
            }
        }
        if let color = request.color {
            try statement.bind(color.rawValue, at: index)
            index += 1
        }
        return index
    }

    private func orderedCursorRowExists(
        localPK: Int64,
        request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        schema: SchemaAvailability
    ) throws -> Bool {
        var predicates = ["a.\(AppleBooksSchema.Annotation.localPK) = ?"]
        predicates += queryPredicates(request, resolvedAssetID: resolvedAssetID, schema: schema, alias: "a")
        let sql = "SELECT 1 AS present FROM \(AppleBooksTable.annotations.rawValue) AS a WHERE \(predicates.map { "(\($0))" }.joined(separator: " AND ")) LIMIT 2"
        let statement = try annotationConnection.prepare(sql)
        try statement.bind(localPK, at: 1)
        _ = try bindQuery(request, resolvedAssetID: resolvedAssetID, to: statement, startingAt: 2)
        guard try statement.step() else { return false }
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return true
    }

    private func orderedCandidatePKs(
        request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        schema: SchemaAvailability,
        anchorPK: Int64?,
        limit: Int
    ) throws -> [Int64] {
        let created = SemanticSQLiteReal.dateSQL("a.\(AppleBooksSchema.Annotation.creationDate)")
        let modified = SemanticSQLiteReal.dateSQL("a.\(AppleBooksSchema.Annotation.modificationDate)")
        var sql = ""
        if let anchorPK {
            guard try orderedCursorRowExists(
                localPK: anchorPK,
                request: request,
                resolvedAssetID: resolvedAssetID,
                schema: schema
            ) else {
                throw CursorPaginationError.staleCursor
            }
            let cursorCreated = SemanticSQLiteReal.dateSQL("c.\(AppleBooksSchema.Annotation.creationDate)")
            let cursorModified = SemanticSQLiteReal.dateSQL("c.\(AppleBooksSchema.Annotation.modificationDate)")
            sql += "WITH cursor_row AS (SELECT c.\(AppleBooksSchema.Annotation.localPK) AS cursorPK, \(cursorCreated) AS cursorCreated, \(cursorModified) AS cursorModified FROM \(AppleBooksTable.annotations.rawValue) AS c WHERE c.\(AppleBooksSchema.Annotation.localPK) = ? LIMIT 1) "
        }
        sql += "SELECT a.\(AppleBooksSchema.Annotation.localPK) AS candidatePK FROM \(AppleBooksTable.annotations.rawValue) AS a"
        if anchorPK != nil { sql += " CROSS JOIN cursor_row AS cursor" }
        var predicates = queryPredicates(request, resolvedAssetID: resolvedAssetID, schema: schema, alias: "a")
        if anchorPK != nil {
            predicates.append(orderedKeysetPredicate(
                request.order,
                created: created,
                modified: modified,
                cursorCreated: "cursor.cursorCreated",
                cursorModified: "cursor.cursorModified",
                cursorPK: "cursor.cursorPK"
            ))
        }
        let order: String
        switch request.order {
        case .created:
            order = "\(created) IS NULL, \(created) DESC, a.\(AppleBooksSchema.Annotation.localPK) DESC"
        case .modified:
            order = "\(modified) IS NULL, \(modified) DESC, \(created) IS NULL, \(created) DESC, a.\(AppleBooksSchema.Annotation.localPK) DESC"
        case .reading:
            throw CursorPaginationError.internalContractFailure
        }
        sql += " WHERE \(predicates.map { "(\($0))" }.joined(separator: " AND ")) ORDER BY \(order) LIMIT ?"
        let statement = try annotationConnection.prepare(sql)
        var index: Int32 = 1
        if let anchorPK {
            try statement.bind(anchorPK, at: index)
            index += 1
        }
        index = try bindQuery(request, resolvedAssetID: resolvedAssetID, to: statement, startingAt: index)
        try statement.bind(Int64(limit), at: index)
        var result: [Int64] = []
        result.reserveCapacity(limit)
        while try statement.step() {
            guard let localPK = try SQLiteRow(statement: statement).int64("candidatePK") else {
                throw QueryDecodingError.nullRequiredColumn("candidatePK")
            }
            result.append(localPK)
        }
        return result
    }

    private func orderedKeysetPredicate(
        _ order: AnnotationQueryOrder,
        created: String,
        modified: String,
        cursorCreated: String,
        cursorModified: String,
        cursorPK: String
    ) -> String {
        let pk = "a.\(AppleBooksSchema.Annotation.localPK)"
        let createdTie = descendingNullableAfter(
            expression: created,
            cursorExpression: cursorCreated,
            tie: "\(pk) < \(cursorPK)"
        )
        switch order {
        case .created:
            return createdTie
        case .modified:
            return descendingNullableAfter(
                expression: modified,
                cursorExpression: cursorModified,
                tie: createdTie
            )
        case .reading:
            return "0"
        }
    }

    private func descendingNullableAfter(
        expression: String,
        cursorExpression: String,
        tie: String
    ) -> String {
        "((\(cursorExpression) IS NULL AND \(expression) IS NULL AND (\(tie))) OR (\(cursorExpression) IS NOT NULL AND (\(expression) IS NULL OR (\(expression) IS NOT NULL AND (\(expression) < \(cursorExpression) OR (\(expression) = \(cursorExpression) AND (\(tie))))))))"
    }

    private func readingProjection(schema: SchemaAvailability, alias: String) -> [String] {
        var projection = ["\(alias).\(AppleBooksSchema.Annotation.localPK) AS readingPK"]
        let created = SemanticSQLiteReal.dateSQL("\(alias).\(AppleBooksSchema.Annotation.creationDate)")
        projection.append("\(created) AS readingCreated")
        if schema.contains(AppleBooksSchema.Annotation.location) {
            projection += SQLiteTextProjection.exact(
                "\(alias).\(AppleBooksSchema.Annotation.location)",
                alias: "readingCFI",
                maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
            )
        }
        return projection
    }

    private func decodeReadingCandidate(_ row: SQLiteRow, schema: SchemaAvailability, chapterOrder: [String: Int]) throws -> ReadingCandidate {
        guard let localPK = try row.int64("readingPK") else {
            throw QueryDecodingError.nullRequiredColumn("readingPK")
        }
        let rawCFI: String?
        if schema.contains(AppleBooksSchema.Annotation.location) {
            switch try SQLiteTextProjection.decodeExact(
                row,
                alias: "readingCFI",
                column: AppleBooksSchema.Annotation.location,
                maximumUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes
            ) {
            case let .value(value): rawCFI = value
            case .null, .oversized: rawCFI = nil
            }
        } else {
            rawCFI = nil
        }
        let createdAt = CoreDataTime.date(from: try row.double("readingCreated"))
        return ReadingCandidate(
            localPK: localPK,
            key: EPUBAnnotationReadingKey.make(
                rawCFI: rawCFI,
                chapterOrder: chapterOrder,
                createdAt: createdAt,
                localPK: localPK
            )
        )
    }

    private func readingAnchor(
        localPK: Int64,
        request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        schema: SchemaAvailability,
        chapterOrder: [String: Int]
    ) throws -> ReadingCandidate {
        var sql = "SELECT \(readingProjection(schema: schema, alias: "a").joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue) AS a"
        var predicates = ["a.\(AppleBooksSchema.Annotation.localPK) = ?"]
        predicates += queryPredicates(request, resolvedAssetID: resolvedAssetID, schema: schema, alias: "a")
        sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ") + " LIMIT 2"
        let statement = try annotationConnection.prepare(sql)
        try statement.bind(localPK, at: 1)
        _ = try bindQuery(request, resolvedAssetID: resolvedAssetID, to: statement, startingAt: 2)
        guard try statement.step() else { throw CursorPaginationError.staleCursor }
        let candidate = try decodeReadingCandidate(SQLiteRow(statement: statement), schema: schema, chapterOrder: chapterOrder)
        guard try statement.step() == false else { throw CursorPaginationError.internalContractFailure }
        return candidate
    }

    private func readingCandidatePKs(
        request: AnnotationQueryRequest,
        resolvedAssetID: String?,
        schema: SchemaAvailability,
        chapterOrder: [String: Int],
        anchor: ReadingCandidate?,
        limit: Int,
        instrumentation: AnnotationQueryInstrumentation?
    ) throws -> [Int64] {
        let sql = "SELECT \(readingProjection(schema: schema, alias: "a").joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue) AS a WHERE \(queryPredicates(request, resolvedAssetID: resolvedAssetID, schema: schema, alias: "a").map { "(\($0))" }.joined(separator: " AND ")) ORDER BY a.\(AppleBooksSchema.Annotation.localPK)"
        let statement = try annotationConnection.prepare(sql)
        _ = try bindQuery(request, resolvedAssetID: resolvedAssetID, to: statement, startingAt: 1)
        var candidates: [ReadingCandidate] = []
        candidates.reserveCapacity(limit)
        while try statement.step() {
            let candidate = try decodeReadingCandidate(SQLiteRow(statement: statement), schema: schema, chapterOrder: chapterOrder)
            if let anchor, EPUBAnnotationReadingKey.lessThan(anchor.key, candidate.key) == false { continue }
            let insertion = candidates.firstIndex { EPUBAnnotationReadingKey.lessThan(candidate.key, $0.key) } ?? candidates.endIndex
            if candidates.count < limit {
                candidates.insert(candidate, at: insertion)
            } else if insertion < candidates.endIndex {
                candidates.removeLast()
                candidates.insert(candidate, at: insertion)
            }
            instrumentation?.observeReadingCandidates(candidates.count)
        }
        return candidates.map(\.localPK)
    }

    private func semanticRows(
        localPKs: [Int64],
        schema: SchemaAvailability,
        instrumentation: AnnotationQueryInstrumentation?
    ) throws -> [SemanticAnnotation] {
        guard localPKs.isEmpty == false else { return [] }
        guard localPKs.count <= AnnotationSourceClassifier.maximumBatch else {
            throw CursorPaginationError.internalContractFailure
        }
        let projection = semanticProjection(schema: schema, textMode: .preview)
        let placeholders = Array(repeating: "?", count: localPKs.count).joined(separator: ",")
        let statement = try annotationConnection.prepare("SELECT \(projection.joined(separator: ", ")) FROM \(AppleBooksTable.annotations.rawValue) WHERE \(AppleBooksSchema.Annotation.localPK) IN (\(placeholders))")
        for (offset, localPK) in localPKs.enumerated() {
            try statement.bind(localPK, at: Int32(offset + 1))
        }
        var byPK: [Int64: SemanticAnnotationRow] = [:]
        byPK.reserveCapacity(localPKs.count)
        while try statement.step() {
            let row = try decodeSemantic(SQLiteRow(statement: statement), schema: schema, textMode: .preview)
            instrumentation?.observeMaterializedSummaryRow()
            guard byPK.updateValue(row, forKey: row.localPK) == nil else {
                throw CursorPaginationError.internalContractFailure
            }
        }
        guard byPK.count == localPKs.count else { throw CursorPaginationError.staleCursor }
        let rows = try localPKs.map { localPK -> SemanticAnnotationRow in
            guard let row = byPK[localPK] else { throw CursorPaginationError.staleCursor }
            return row
        }
        return try enrichSemantic(rows)
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
            isUnderline: AnnotationContentSemantics.underline(
                storageValue: try int64(AppleBooksSchema.Annotation.isUnderline)
            ),
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
            isUnderline: schema.contains(AppleBooksSchema.Annotation.isUnderline)
                ? AnnotationContentSemantics.underline(
                    storageValue: try int64(AppleBooksSchema.Annotation.isUnderline)
                )
                : nil,
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

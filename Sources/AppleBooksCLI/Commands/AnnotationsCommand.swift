import AppleBooksCore
import ArgumentParser
import Foundation

struct AnnotationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotations",
        abstract: "Read, group, search, and inspect Apple Books annotations.",
        subcommands: [
            AnnotationsListCommand.self,
            AnnotationsGetCommand.self,
            AnnotationsSearchCommand.self,
            AnnotationsRecentCommand.self,
            AnnotationsRangeCommand.self,
            AnnotationsUpdateNoteCommand.self,
            AnnotationsDeleteCommand.self,
        ]
    )
}

enum AnnotationCLIScope: String, ExpressibleByArgument, Sendable {
    case user
    case activeRaw = "active-raw"

    var coreValue: AnnotationScope {
        switch self {
        case .user: .user
        case .activeRaw: .activeRaw
        }
    }
}

enum AnnotationCLIOrder: String, ExpressibleByArgument, Sendable {
    case source
    case reading
}

enum AnnotationCLIGroupBy: String, ExpressibleByArgument, Sendable {
    case book
}

enum AnnotationSearchField: String, ExpressibleByArgument, Sendable {
    case all
    case highlight
    case note
}

enum AnnotationColorArgument: String, ExpressibleByArgument, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple
}

enum AnnotationTimeField: String, ExpressibleByArgument, Sendable {
    case created
    case modified
}

struct AnnotationsListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List annotations in source order or canonical per-book reading order."
    )

    @Option(name: .long, help: "Annotation scope: user or active-raw.")
    var scope: AnnotationCLIScope = .user

    @Option(name: .long, help: "Filter by exact Apple Books asset ID.")
    var book: String?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Filter by explicit local book primary key.")
    var bookPK: Int64?

    @Option(name: .customLong("group-by"), help: "Group presentation by book.")
    var groupBy: AnnotationCLIGroupBy?

    @Option(name: .long, help: "Order annotations by source or per-book reading order.")
    var order: AnnotationCLIOrder = .source

    @Option(name: .long, parsing: .unconditional, help: "Limit the stable result order.")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Offset into the stable result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> AnnotationCollectionResult {
        try validateAnnotationPagination(limit: limit, offset: offset)
        let bookSelector = try parseOptionalBookSelector(
            assetID: book,
            localPK: bookPK,
            localPKOptionName: "--book-pk"
        )
        if order == .reading {
            guard scope == .user else {
                throw ValidationError("Reading order is available only for --scope user.")
            }
            guard bookSelector != nil || groupBy == .book else {
                throw ValidationError("Reading order requires --book/--book-pk or --group-by book.")
            }
        }

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])

            if let bookSelector {
                guard let selectedBook = try bookSelector.resolveSemanticDetail(in: books) else {
                    throw CLIError.notFound("Book not found.")
                }
                let rows: [SemanticAnnotation]
                switch order {
                case .source:
                    rows = try books.semanticAnnotations(
                        bookLocalPK: selectedBook.localPK,
                        scope: scope.coreValue,
                        limit: limit,
                        offset: offset
                    )
                case .reading:
                    rows = try books.semanticAnnotationsInReadingOrder(
                        bookLocalPK: selectedBook.localPK,
                        limit: limit,
                        offset: offset
                    )
                }
                return AnnotationCollectionResult(
                    semantic: rows,
                    limit: limit,
                    offset: offset,
                    groupedByBook: groupBy == .book
                )
            }

            if order == .reading {
                let ordered = try crossBookReadingOrder(from: books)
                let rows = paginateAnnotations(ordered, limit: limit, offset: offset)
                return AnnotationCollectionResult(
                    semantic: rows,
                    limit: limit,
                    offset: offset,
                    groupedByBook: true
                )
            }

            let rows: [SemanticAnnotation]
            if groupBy == .book, scope == .user {
                // Grouped user presentation is defined from the core creation-recent owner.
                rows = try books.semanticRecentlyCreatedAnnotations(limit: limit, offset: offset)
            } else {
                rows = try books.semanticAnnotations(scope: scope.coreValue, limit: limit, offset: offset)
            }
            return AnnotationCollectionResult(
                semantic: rows,
                limit: limit,
                offset: offset,
                groupedByBook: groupBy == .book
            )
        }
    }

    private func crossBookReadingOrder(from books: AppleBooks) throws -> [SemanticAnnotation] {
        let sourceRows = try books.semanticAnnotations(scope: .user)
        let currentBookPKs = Set(sourceRows.compactMap { row -> Int64? in
            guard row.source.kind == .currentLibrary else { return nil }
            return row.source.bookLocalPK
        })

        var ordered: [SemanticAnnotation] = []
        var emitted = Set<Int64>()
        for book in try books.semanticBookSummariesInCanonicalOrder() where currentBookPKs.contains(book.localPK) {
            for row in try books.semanticAnnotationsInReadingOrder(bookLocalPK: book.localPK) {
                guard row.source.kind == .currentLibrary,
                      row.source.bookLocalPK == book.localPK,
                      emitted.insert(row.localPK).inserted else {
                    continue
                }
                ordered.append(row)
            }
        }

        for row in sourceRows where emitted.insert(row.localPK).inserted {
            ordered.append(row)
        }
        return ordered
    }
}

struct AnnotationsGetCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get one annotation by exact UUID or explicit local primary key."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local annotation primary key.")
    var pk: Int64?

    @Option(name: .long, help: "Annotation scope: user or active-raw.")
    var scope: AnnotationCLIScope = .user

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> AnnotationResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            guard let row = try selector.resolveSemantic(in: books, scope: scope.coreValue) else {
                throw CLIError.notFound("Annotation not found.")
            }
            return AnnotationResult(row, detail: true)
        }
    }
}

struct AnnotationsSearchCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search canonical annotation text fields with optional named color filtering."
    )

    @Argument(help: "Literal partial-match query.")
    var query: String

    @Option(name: .long, help: "Search all text, highlight text, or note text.")
    var field: AnnotationSearchField = .all

    @Option(name: .long, help: "Filter by a named annotation color.")
    var color: AnnotationColorArgument?

    @Option(name: .long, parsing: .unconditional, help: "Limit the stable search result order.")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Offset into the stable search result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> AnnotationCollectionResult {
        guard query.isEmpty == false else {
            throw ValidationError("Search query must not be empty.")
        }
        try validateAnnotationPagination(limit: limit, offset: offset)

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            let rows: [SemanticAnnotation]
            switch field {
            case .all:
                rows = try books.semanticAnnotations(
                    matchingText: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            case .highlight:
                rows = try books.semanticAnnotations(
                    matchingHighlightedText: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            case .note:
                rows = try books.semanticAnnotations(
                    matchingNote: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            }
            return AnnotationCollectionResult(semantic: rows, limit: limit, offset: offset)
        }
    }
}

struct AnnotationsRecentCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "recent",
        abstract: "Read the canonical created-recent or modified-recent annotation view."
    )

    @Option(name: .customLong("time-field"), help: "Use created or modified time ordering.")
    var timeField: AnnotationTimeField = .created

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute() throws -> AnnotationCollectionResult {
        try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            let rows: [SemanticAnnotation]
            switch timeField {
            case .created:
                rows = try books.semanticRecentlyCreatedAnnotations()
            case .modified:
                rows = try books.semanticRecentlyModifiedAnnotations()
            }
            return AnnotationCollectionResult(semantic: rows, limit: 10, offset: 0)
        }
    }
}

struct AnnotationsRangeCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "range",
        abstract: "List user annotations in a half-open creation-time range."
    )

    @Option(name: .long, help: "Inclusive RFC3339 instant or local YYYY-MM-DD lower bound.")
    var after: String?

    @Option(name: .long, help: "Exclusive RFC3339 instant or inclusive local YYYY-MM-DD calendar day.")
    var before: String?

    @Option(name: .long, parsing: .unconditional, help: "Limit the stable range result order.")
    var limit: Int?

    @Option(name: .long, parsing: .unconditional, help: "Offset into the stable range result order.")
    var offset = 0

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(calendar: Calendar = .autoupdatingCurrent) throws -> AnnotationCollectionResult {
        try validateAnnotationPagination(limit: limit, offset: offset)
        let range = try AnnotationDateRangeParser(calendar: calendar).parse(after: after, before: before)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            let rows = try books.semanticAnnotations(
                createdAtOrAfter: range.lowerInclusive,
                beforeExclusive: range.upperExclusive,
                limit: limit,
                offset: offset
            )
            return AnnotationCollectionResult(semantic: rows, limit: limit, offset: offset)
        }
    }
}

struct AnnotationsUpdateNoteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "update-note",
        abstract: "Update one annotation note through the guarded mutation rail."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local annotation primary key.")
    var pk: Int64?

    @Option(name: .long, help: "Replacement note text.")
    var note: String

    @Flag(name: .long, help: "After local commit, wait for current-Mac CloudKit acknowledgement. Omit for local-only writes; use root sync to flush pending changes later.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "annotations.update-note" }

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .annotationWrite)
            return MutationCommandResult(try selector.updateNote(note, in: books, syncCloud: sync))
        }
    }
}

struct AnnotationsDeleteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Soft-delete one annotation through the guarded mutation rail."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local annotation primary key.")
    var pk: Int64?

    @Flag(name: .long, help: "After local commit, wait for current-Mac CloudKit acknowledgement. Omit for local-only writes; use root sync to flush pending changes later.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "annotations.delete" }

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        try output.writeJSON(result)
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(dependencies: .annotationWrite)
            return MutationCommandResult(try selector.delete(in: books, syncCloud: sync))
        }
    }
}

struct AnnotationDateRange: Equatable, Sendable {
    let lowerInclusive: Date?
    let upperExclusive: Date?
}

struct AnnotationDateRangeParser {
    let calendar: Calendar

    func parse(after: String?, before: String?) throws -> AnnotationDateRange {
        guard after != nil || before != nil else {
            throw ValidationError("Provide --after, --before, or both.")
        }

        let lower = try after.map { try boundary($0, dateOnlyAsUpperBound: false) }
        let upper = try before.map { try boundary($0, dateOnlyAsUpperBound: true) }
        if let lower, let upper, lower >= upper {
            throw ValidationError("--after must be earlier than --before.")
        }
        return AnnotationDateRange(lowerInclusive: lower, upperExclusive: upper)
    }

    private func boundary(_ raw: String, dateOnlyAsUpperBound: Bool) throws -> Date {
        if let components = dateOnlyComponents(raw) {
            let localCalendar = calendar
            guard let date = localCalendar.date(from: components) else {
                throw ValidationError("Invalid annotation date boundary.")
            }
            let start = localCalendar.startOfDay(for: date)
            let roundTrip = localCalendar.dateComponents([.year, .month, .day], from: start)
            guard roundTrip.year == components.year,
                  roundTrip.month == components.month,
                  roundTrip.day == components.day else {
                throw ValidationError("Invalid annotation date boundary.")
            }
            guard dateOnlyAsUpperBound else { return start }
            guard let nextDay = localCalendar.date(byAdding: .day, value: 1, to: start) else {
                throw ValidationError("Invalid annotation date boundary.")
            }
            return nextDay
        }

        if let instant = Self.rfc3339Date(raw) {
            return instant
        }
        throw ValidationError("Invalid annotation date boundary.")
    }

    private func dateOnlyComponents(_ raw: String) -> DateComponents? {
        guard raw.utf8.count == 10 else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = year
        components.month = month
        components.day = day
        return components
    }

    private static func rfc3339Date(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let integral = ISO8601DateFormatter()
        integral.formatOptions = [.withInternetDateTime]
        return integral.date(from: raw)
    }
}

struct AnnotationCollectionResult: Codable, Equatable, Sendable {
    let items: [AnnotationResult]
    let limit: Int?
    let offset: Int
    let groups: [AnnotationGroupResult]?

    init(
        semantic: [SemanticAnnotation],
        limit: Int?,
        offset: Int,
        groupedByBook: Bool = false
    ) {
        items = semantic.map { AnnotationResult($0) }
        self.limit = limit
        self.offset = offset
        groups = groupedByBook ? makeAnnotationGroups(semantic) : nil
    }

}

struct AnnotationGroupResult: Codable, Equatable, Sendable {
    let source: AnnotationSourceResult
    let rawAssetID: String?
    let annotationLocalPKs: [Int64]

    var humanTitle: String {
        switch source.kind {
        case "currentLibrary":
            return source.title ?? rawAssetID ?? source.bookLocalPK.map(String.init) ?? "Current book"
        case "historicalInferred":
            return source.title ?? rawAssetID ?? "Historical book"
        default:
            return rawAssetID.map { "Unmapped: \($0)" } ?? "Unmapped"
        }
    }
}

struct AnnotationSourceResult: Codable, Equatable, Sendable {
    let kind: String
    let bookLocalPK: Int64?
    let bookAssetID: String?
    let title: String?
    let author: String?

    init(_ source: SemanticAnnotationSource, truncatedFields: inout [String]) {
        kind = source.kind.rawValue
        bookLocalPK = source.bookLocalPK
        bookAssetID = source.bookAssetID
        truncatedFields.append(contentsOf: source.byteTruncatedFields.map { "source.\($0)" })
        title = boundedField(
            source.title,
            field: "source.title",
            profile: .metadata,
            truncatedFields: &truncatedFields
        )
        author = boundedField(
            source.author,
            field: "source.author",
            profile: .metadata,
            truncatedFields: &truncatedFields
        )
    }
}

struct AnnotationResult: Codable, Equatable, Sendable {
    let localPK: Int64
    let uuid: String?
    let rawAssetID: String?
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
    let appleBooksURL: String?
    let chapterHint: String?
    let physicalLocation: Int64?
    let rangeStart: Int64?
    let rangeEnd: Int64?
    let source: AnnotationSourceResult
    let truncatedFields: [String]

    init(_ annotation: SemanticAnnotation, detail: Bool = false) {
        localPK = annotation.localPK
        uuid = annotation.uuid
        rawAssetID = annotation.rawAssetID
        isDeleted = annotation.isDeleted
        isUnderline = annotation.isUnderline
        style = annotation.style
        type = annotation.type
        createdAt = annotation.createdAt
        modifiedAt = annotation.modifiedAt
        var truncated = annotation.byteTruncatedFields
        representativeText = boundedField(
            annotation.representativeText,
            field: "representativeText",
            profile: .preview,
            truncatedFields: &truncated
        )
        let bodyProfile: BoundedTextProfile = detail ? .detail : .preview
        selectedText = boundedField(
            annotation.selectedText,
            field: "selectedText",
            profile: bodyProfile,
            truncatedFields: &truncated
        )
        note = boundedField(
            annotation.note,
            field: "note",
            profile: bodyProfile,
            truncatedFields: &truncated
        )
        rawCFI = annotation.rawCFI
        appleBooksURL = annotation.appleBooksURL
        chapterHint = boundedField(
            annotation.chapterHint,
            field: "chapterHint",
            profile: .metadata,
            truncatedFields: &truncated
        )
        physicalLocation = annotation.physicalLocation
        rangeStart = annotation.rangeStart
        rangeEnd = annotation.rangeEnd
        source = AnnotationSourceResult(annotation.source, truncatedFields: &truncated)
        var unique: [String] = []
        unique.reserveCapacity(truncated.count)
        for field in truncated where unique.contains(field) == false { unique.append(field) }
        truncatedFields = unique
    }

}

private enum AnnotationBookGroupKey: Hashable {
    case current(Int64)
    case classified(kind: SemanticAnnotationSourceKind, rawAssetID: String?)
}

private func makeAnnotationGroups(_ rows: [SemanticAnnotation]) -> [AnnotationGroupResult] {
    var indices: [AnnotationBookGroupKey: Int] = [:]
    var groups: [(source: AnnotationSourceResult, rawAssetID: String?, localPKs: [Int64])] = []

    for row in rows {
        let key: AnnotationBookGroupKey
        if row.source.kind == .currentLibrary, let localPK = row.source.bookLocalPK {
            key = .current(localPK)
        } else {
            key = .classified(kind: row.source.kind, rawAssetID: row.rawAssetID)
        }

        if let index = indices[key] {
            groups[index].localPKs.append(row.localPK)
        } else {
            indices[key] = groups.count
            var truncated: [String] = []
            groups.append((
                source: AnnotationSourceResult(row.source, truncatedFields: &truncated),
                rawAssetID: row.rawAssetID,
                localPKs: [row.localPK]
            ))
        }
    }

    return groups.map {
        AnnotationGroupResult(
            source: $0.source,
            rawAssetID: $0.rawAssetID,
            annotationLocalPKs: $0.localPKs
        )
    }
}

private func validateAnnotationPagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 {
        throw ValidationError("--limit must be positive.")
    }
    guard offset >= 0 else {
        throw ValidationError("--offset must be non-negative.")
    }
}

private func paginateAnnotations(
    _ rows: [SemanticAnnotation],
    limit: Int?,
    offset: Int
) -> [SemanticAnnotation] {
    let suffix = rows.dropFirst(offset)
    guard let limit else { return Array(suffix) }
    return Array(suffix.prefix(limit))
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.first { value in
        guard let value else { return false }
        return value.isEmpty == false
    } ?? nil
}

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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
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
            let books = try CLIContext(global: global).makeAppleBooks()

            if let bookSelector {
                guard let selectedBook = try bookSelector.resolve(in: books) else {
                    throw CLIError.notFound("Book not found.")
                }
                let rows: [EnrichedAnnotation]
                switch order {
                case .source:
                    rows = try books.annotations(
                        bookLocalPK: selectedBook.localPK,
                        scope: scope.coreValue,
                        limit: limit,
                        offset: offset
                    )
                case .reading:
                    rows = try books.annotationsInReadingOrder(
                        bookLocalPK: selectedBook.localPK,
                        limit: limit,
                        offset: offset
                    )
                }
                return AnnotationCollectionResult(
                    enriched: rows,
                    limit: limit,
                    offset: offset,
                    groupedByBook: groupBy == .book
                )
            }

            if order == .reading {
                let ordered = try crossBookReadingOrder(from: books)
                let rows = paginateAnnotations(ordered, limit: limit, offset: offset)
                return AnnotationCollectionResult(
                    enriched: rows,
                    limit: limit,
                    offset: offset,
                    groupedByBook: true
                )
            }

            let rows: [EnrichedAnnotation]
            if groupBy == .book, scope == .user {
                // Grouped user presentation is defined from the core creation-recent owner.
                rows = try books.recentlyCreatedAnnotations(limit: limit, offset: offset)
            } else {
                rows = try books.listAnnotations(scope: scope.coreValue, limit: limit, offset: offset)
            }
            return AnnotationCollectionResult(
                enriched: rows,
                limit: limit,
                offset: offset,
                groupedByBook: groupBy == .book
            )
        }
    }

    private func crossBookReadingOrder(from books: AppleBooks) throws -> [EnrichedAnnotation] {
        let sourceRows = try books.listAnnotations(scope: .user)
        let currentBookPKs = Set(sourceRows.compactMap { row -> Int64? in
            guard case let .currentLibrary(book) = row.source else { return nil }
            return book.localPK
        })

        var ordered: [EnrichedAnnotation] = []
        var emitted = Set<Int64>()
        for book in try books.listBooks() where currentBookPKs.contains(book.localPK) {
            for row in try books.annotationsInReadingOrder(bookLocalPK: book.localPK) {
                guard case let .currentLibrary(sourceBook) = row.source,
                      sourceBook.localPK == book.localPK,
                      emitted.insert(row.annotation.localPK).inserted else {
                    continue
                }
                ordered.append(row)
            }
        }

        for row in sourceRows where emitted.insert(row.annotation.localPK).inserted {
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> AnnotationResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            guard let row = try selector.resolve(in: books, scope: scope.coreValue) else {
                throw CLIError.notFound("Annotation not found.")
            }
            return AnnotationResult(row)
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> AnnotationCollectionResult {
        guard query.isEmpty == false else {
            throw ValidationError("Search query must not be empty.")
        }
        try validateAnnotationPagination(limit: limit, offset: offset)

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let rows: [EnrichedAnnotation]
            switch field {
            case .all:
                rows = try books.annotations(
                    matchingText: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            case .highlight:
                rows = try books.annotations(
                    matchingHighlightedText: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            case .note:
                rows = try books.annotations(
                    matchingNote: query,
                    colorName: color?.rawValue,
                    limit: limit,
                    offset: offset
                )
            }
            return AnnotationCollectionResult(enriched: rows, limit: limit, offset: offset)
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute() throws -> AnnotationCollectionResult {
        try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let rows: [EnrichedAnnotation]
            switch timeField {
            case .created:
                rows = try books.recentlyCreatedAnnotations()
            case .modified:
                rows = try books.recentlyModifiedAnnotations()
            }
            return AnnotationCollectionResult(enriched: rows, limit: 10, offset: 0)
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
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute(calendar: Calendar = .autoupdatingCurrent) throws -> AnnotationCollectionResult {
        try validateAnnotationPagination(limit: limit, offset: offset)
        let range = try AnnotationDateRangeParser(calendar: calendar).parse(after: after, before: before)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks()
            let rows = try books.annotations(
                createdAtOrAfter: range.lowerInclusive,
                beforeExclusive: range.upperExclusive,
                limit: limit,
                offset: offset
            )
            return AnnotationCollectionResult(enriched: rows, limit: limit, offset: offset)
        }
    }
}

struct AnnotationsUpdateNoteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
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

    @Flag(name: .long, help: "After local commit, trigger Apple Books cloud sync and wait for CloudKit acknowledgement.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selector.updateNote(note, in: books, syncCloud: sync))
        }
    }
}

struct AnnotationsDeleteCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Soft-delete one annotation through the guarded mutation rail."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local annotation primary key.")
    var pk: Int64?

    @Flag(name: .long, help: "After local commit, trigger Apple Books cloud sync and wait for CloudKit acknowledgement.")
    var sync = false

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try execute()
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> MutationCommandResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks()
            return MutationCommandResult(try selector.delete(in: books, syncCloud: sync))
        }
    }
}

struct MutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let backupHandle: String
    let localPK: Int64?
    let stableID: String?
    let warningCodes: [String]

    init(_ result: MutationResult) {
        committed = result.committed
        changed = result.changed
        backupHandle = result.backupHandle
        localPK = result.localPK
        stableID = result.stableID
        warningCodes = result.warnings.map(\.rawValue)
    }

    var humanDescription: String {
        var lines = [
            "committed: \(committed)",
            "changed: \(changed)",
            "backup: \(backupHandle)",
            "local PK: \(localPK.map(String.init) ?? "-")",
        ]
        if warningCodes.isEmpty == false {
            lines.append("warnings: \(warningCodes.joined(separator: ","))")
        }
        return lines.joined(separator: "\n")
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
        enriched: [EnrichedAnnotation],
        limit: Int?,
        offset: Int,
        groupedByBook: Bool = false
    ) {
        items = enriched.map(AnnotationResult.init)
        self.limit = limit
        self.offset = offset
        groups = groupedByBook ? makeAnnotationGroups(enriched) : nil
    }

    var humanDescription: String {
        guard items.isEmpty == false else { return "No annotations." }
        guard let groups else {
            return items.map(\.humanSummary).joined(separator: "\n")
        }

        let byPK = Dictionary(uniqueKeysWithValues: items.map { ($0.localPK, $0) })
        return groups.map { group in
            var lines = ["[\(group.humanTitle)]"]
            lines.append(contentsOf: group.annotationLocalPKs.compactMap { byPK[$0]?.humanSummary })
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
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

    init(_ source: AnnotationSource) {
        switch source {
        case let .currentLibrary(book):
            kind = "currentLibrary"
            bookLocalPK = book.localPK
            bookAssetID = book.assetID
            title = book.title
            author = book.author
        case let .historicalInferred(metadata):
            kind = "historicalInferred"
            bookLocalPK = nil
            bookAssetID = nil
            title = metadata.title
            author = metadata.author
        case .unmapped:
            kind = "unmapped"
            bookLocalPK = nil
            bookAssetID = nil
            title = nil
            author = nil
        }
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

    init(_ enriched: EnrichedAnnotation) {
        let annotation = enriched.annotation
        localPK = annotation.localPK
        uuid = annotation.uuid
        rawAssetID = annotation.rawAssetID
        isDeleted = annotation.isDeleted
        isUnderline = annotation.isUnderline
        style = annotation.style
        type = annotation.type
        createdAt = annotation.createdAt
        modifiedAt = annotation.modifiedAt
        representativeText = annotation.representativeText
        selectedText = annotation.selectedText
        note = annotation.note
        rawCFI = annotation.location?.rawCFI
        appleBooksURL = annotation.appleBooksURL
        chapterHint = annotation.chapterHint
        physicalLocation = annotation.physicalLocation
        rangeStart = annotation.rangeStart
        rangeEnd = annotation.rangeEnd
        source = AnnotationSourceResult(enriched.source)
    }

    var humanDescription: String {
        [
            "local PK: \(localPK)",
            "UUID: \(uuid ?? "-")",
            "asset ID: \(rawAssetID ?? "-")",
            "type: \(type.map(String.init) ?? "-")",
            "style: \(style.map(String.init) ?? "-")",
            "underline: \(isUnderline.map(String.init) ?? "-")",
            "CFI: \(rawCFI ?? "-")",
            "Apple Books URL: \(appleBooksURL ?? "-")",
            "selected text: \(selectedText ?? "-")",
            "note: \(note ?? "-")",
            "source: \(source.kind)",
        ].joined(separator: "\n")
    }

    var humanSummary: String {
        let text = firstNonEmpty(selectedText, representativeText, note)?
            .replacingOccurrences(of: "\n", with: " ") ?? "-"
        return "\(localPK)\t\(uuid ?? "-")\t\(rawAssetID ?? "-")\t\(text)"
    }
}

private enum AnnotationBookGroupKey: Hashable {
    case current(Int64)
    case historical(String?)
    case unmapped(String?)
}

private func makeAnnotationGroups(_ rows: [EnrichedAnnotation]) -> [AnnotationGroupResult] {
    var indices: [AnnotationBookGroupKey: Int] = [:]
    var groups: [(source: AnnotationSourceResult, rawAssetID: String?, localPKs: [Int64])] = []

    for row in rows {
        let key: AnnotationBookGroupKey
        switch row.source {
        case let .currentLibrary(book):
            key = .current(book.localPK)
        case .historicalInferred:
            key = .historical(row.annotation.rawAssetID)
        case .unmapped:
            key = .unmapped(row.annotation.rawAssetID)
        }

        if let index = indices[key] {
            groups[index].localPKs.append(row.annotation.localPK)
        } else {
            indices[key] = groups.count
            groups.append((
                source: AnnotationSourceResult(row.source),
                rawAssetID: row.annotation.rawAssetID,
                localPKs: [row.annotation.localPK]
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
    _ rows: [EnrichedAnnotation],
    limit: Int?,
    offset: Int
) -> [EnrichedAnnotation] {
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

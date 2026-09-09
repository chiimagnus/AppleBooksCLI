import AppleBooksCore
import ArgumentParser
import Foundation

struct AnnotationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotations",
        abstract: "Read, search, and inspect Apple Books annotations.",
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
    case created
    case modified
    case reading

    var coreValue: AnnotationQueryOrder {
        switch self {
        case .created: .created
        case .modified: .modified
        case .reading: .reading
        }
    }
}

enum AnnotationSearchField: String, ExpressibleByArgument, Sendable {
    case all
    case highlight
    case note

    var queryValue: AnnotationQueryTextField {
        switch self {
        case .all: .all
        case .highlight: .highlight
        case .note: .note
        }
    }
}

enum AnnotationColorArgument: String, ExpressibleByArgument, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple

    var queryValue: AnnotationColor {
        switch self {
        case .green: .green
        case .blue: .blue
        case .yellow: .yellow
        case .pink: .pink
        case .purple: .purple
        }
    }
}

enum AnnotationBooleanArgument: String, ExpressibleByArgument, Sendable {
    case trueValue = "true"
    case falseValue = "false"

    var value: Bool { self == .trueValue }
}

enum AnnotationTimeField: String, ExpressibleByArgument, Sendable {
    case created
    case modified
}

struct AnnotationsListCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Query user annotations with bounded semantic summaries and opaque cursor pagination."
    )

    @Option(name: .long, help: "Filter by exact Apple Books asset ID.")
    var book: String?

    @Option(name: .customLong("book-pk"), parsing: .unconditional, help: "Filter by explicit local book primary key.")
    var bookPK: Int64?

    @Option(name: .long, help: "Literal text filter.")
    var text: String?

    @Option(name: .customLong("text-field"), help: "Search all, highlight, or note text.")
    var textField: AnnotationSearchField?

    @Option(name: .customLong("created-after"), help: "Inclusive timezone-bearing RFC3339 creation instant.")
    var createdAfter: String?

    @Option(name: .customLong("created-before"), help: "Exclusive timezone-bearing RFC3339 creation instant.")
    var createdBefore: String?

    @Option(name: .customLong("modified-after"), help: "Inclusive timezone-bearing RFC3339 modification instant.")
    var modifiedAfter: String?

    @Option(name: .customLong("modified-before"), help: "Exclusive timezone-bearing RFC3339 modification instant.")
    var modifiedBefore: String?

    @Option(name: .long, help: "Filter by a named annotation color.")
    var color: AnnotationColorArgument?

    @Option(name: .long, help: "Filter underline state: true or false.")
    var underline: AnnotationBooleanArgument?

    @Option(name: .customLong("has-highlight"), help: "Require highlight presence: true or false.")
    var hasHighlight: AnnotationBooleanArgument?

    @Option(name: .customLong("has-note"), help: "Require note presence: true or false.")
    var hasNote: AnnotationBooleanArgument?

    @Option(name: .long, help: "Order by created, modified, or exact-book reading position.")
    var order: AnnotationCLIOrder = .modified

    @Option(name: .long, parsing: .unconditional, help: "Page size from 1 through 100. Defaults to 20.")
    var limit: Int?

    @Option(name: .long, help: "Opaque continuation cursor from the previous page.")
    var cursor: String?

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute() throws -> AnnotationListResult {
        let bookSelector = try parseOptionalBookSelector(
            assetID: book,
            localPK: bookPK,
            localPKOptionName: "--book-pk"
        )
        try validateAnnotationListPageInput(limit: limit, cursor: cursor)
        let request = try makeAnnotationQueryRequest(
            book: bookSelector,
            text: text,
            textField: textField,
            createdAfter: createdAfter,
            createdBefore: createdBefore,
            modifiedAfter: modifiedAfter,
            modifiedBefore: modifiedBefore,
            color: color,
            underline: underline,
            hasHighlight: hasHighlight,
            hasNote: hasNote,
            order: order,
            limit: limit,
            cursor: cursor
        )

        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            return AnnotationListResult(try books.semanticAnnotationPage(request))
        }
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

    func execute() throws -> AnnotationDetailResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration])
            guard let row = try selector.resolveSemantic(in: books, scope: scope.coreValue) else {
                throw CLIError.notFound("Annotation not found.")
            }
            return AnnotationDetailResult(row)
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

private func validateAnnotationListPageInput(limit: Int?, cursor: String?) throws {
    if let limit, (1...100).contains(limit) == false {
        throw ValidationError("--limit must be between 1 and 100.")
    }
    do {
        try validateCursorInputSyntax(cursor)
    } catch {
        throw ValidationError("Invalid annotation cursor.")
    }
}

private func makeAnnotationQueryRequest(
    book: BookSelector?,
    text: String?,
    textField: AnnotationSearchField?,
    createdAfter: String?,
    createdBefore: String?,
    modifiedAfter: String?,
    modifiedBefore: String?,
    color: AnnotationColorArgument?,
    underline: AnnotationBooleanArgument?,
    hasHighlight: AnnotationBooleanArgument?,
    hasNote: AnnotationBooleanArgument?,
    order: AnnotationCLIOrder,
    limit: Int?,
    cursor: String?
) throws -> AnnotationQueryRequest {
    let queryBook: AnnotationQueryBookSelector? = switch book {
    case nil: nil
    case let .assetID(assetID): .assetID(assetID)
    case let .localPK(localPK): .localPK(localPK)
    }
    do {
        return try AnnotationQueryRequest(
            book: queryBook,
            text: text,
            textField: textField?.queryValue,
            createdAfter: try parseCanonicalAnnotationInstant(createdAfter, optionName: "--created-after"),
            createdBefore: try parseCanonicalAnnotationInstant(createdBefore, optionName: "--created-before"),
            modifiedAfter: try parseCanonicalAnnotationInstant(modifiedAfter, optionName: "--modified-after"),
            modifiedBefore: try parseCanonicalAnnotationInstant(modifiedBefore, optionName: "--modified-before"),
            color: color?.queryValue,
            underline: underline?.value,
            hasHighlight: hasHighlight?.value,
            hasNote: hasNote?.value,
            order: order.coreValue,
            limit: limit,
            cursor: cursor
        )
    } catch is AnnotationQueryRequestError {
        throw ValidationError("Invalid annotation query.")
    }
}

private func parseCanonicalAnnotationInstant(_ raw: String?, optionName: String) throws -> Date? {
    guard let raw else { return nil }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)
    for byte in raw.utf8 {
        guard byte < 0x80, bytes.count < 64 else {
            throw ValidationError("\(optionName) must be a timezone-bearing RFC3339 instant.")
        }
        bytes.append(byte)
    }
    guard bytes.count >= 20,
          bytes.count > 10,
          bytes[10] == 0x54 || bytes[10] == 0x74 else {
        throw ValidationError("\(optionName) must be a timezone-bearing RFC3339 instant.")
    }

    let hasZulu = bytes.last == 0x5a || bytes.last == 0x7a
    var hasOffset = false
    if bytes.count >= 6 {
        let start = bytes.count - 6
        let sign = bytes[start] == 0x2b || bytes[start] == 0x2d
        let colon = bytes[start + 3] == 0x3a
        let digits = [bytes[start + 1], bytes[start + 2], bytes[start + 4], bytes[start + 5]]
            .allSatisfy { (0x30...0x39).contains($0) }
        hasOffset = sign && colon && digits
    }
    guard hasZulu || hasOffset else {
        throw ValidationError("\(optionName) must include an explicit timezone.")
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let value = fractional.date(from: raw) { return value }
    let integral = ISO8601DateFormatter()
    integral.formatOptions = [.withInternetDateTime]
    guard let value = integral.date(from: raw) else {
        throw ValidationError("\(optionName) must be a valid RFC3339 instant.")
    }
    return value
}

struct AnnotationListResult: Codable, Equatable, Sendable {
    let items: [AnnotationSummaryResult]
    let nextCursor: String?
    let hasMore: Bool

    init(_ page: CursorPage<SemanticAnnotation>) {
        items = page.items.map(AnnotationSummaryResult.init)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
    }
}

struct AnnotationPublicSourceResult: Codable, Equatable, Sendable {
    let kind: String
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let title: String?
    let author: String?

    init(_ annotation: SemanticAnnotation, truncatedFields: inout [String]) {
        let semantic = annotation.source
        kind = semantic.kind.rawValue
        let stableCandidate: String? = switch semantic.kind {
        case .currentLibrary:
            semantic.bookAssetID ?? annotation.rawAssetID
        case .historicalInferred, .unmapped:
            annotation.rawAssetID
        case .ambiguousCurrent, .identityUnavailable, .schemaUnavailable:
            nil
        }
        if PublicStableTokenPolicy.isEligible(stableCandidate) {
            bookAssetID = stableCandidate
            bookLocalPK = nil
        } else {
            bookAssetID = nil
            bookLocalPK = semantic.kind == .currentLibrary
                ? semantic.bookLocalPK.flatMap { LocalPKPolicy.isEligible($0) ? $0 : nil }
                : nil
        }
        truncatedFields.append(contentsOf: semantic.byteTruncatedFields.map { "source.\($0)" })
        title = boundedField(
            semantic.title,
            field: "source.title",
            profile: .metadata,
            truncatedFields: &truncatedFields
        )
        author = boundedField(
            semantic.author,
            field: "source.author",
            profile: .metadata,
            truncatedFields: &truncatedFields
        )
    }
}

struct AnnotationSummaryResult: Codable, Equatable, Sendable {
    let uuid: String?
    let localPK: Int64?
    let quotePreview: String?
    let notePreview: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let hasHighlight: Bool
    let hasNote: Bool
    let color: String?
    let underline: Bool
    let source: AnnotationPublicSourceResult
    let truncatedFields: [String]

    init(_ annotation: SemanticAnnotation) {
        let stableUUID = PublicStableTokenPolicy.isEligible(annotation.uuid) ? annotation.uuid : nil
        uuid = stableUUID
        localPK = stableUUID == nil && LocalPKPolicy.isEligible(annotation.localPK) ? annotation.localPK : nil
        hasHighlight = annotation.hasHighlight
        hasNote = annotation.hasNote
        createdAt = annotation.createdAt
        modifiedAt = annotation.modifiedAt
        color = annotationColorName(annotation.style)
        underline = annotation.isUnderline == true

        var truncated = annotation.byteTruncatedFields.compactMap { field -> String? in
            switch field {
            case "selectedText", "representativeText": "quotePreview"
            case "note": "notePreview"
            default: nil
            }
        }
        let rawQuote = AnnotationContentSemantics.hasContent(annotation.selectedText)
            ? annotation.selectedText
            : (AnnotationContentSemantics.hasContent(annotation.representativeText) ? annotation.representativeText : nil)
        quotePreview = boundedField(
            rawQuote,
            field: "quotePreview",
            profile: .preview,
            truncatedFields: &truncated
        )
        notePreview = boundedField(
            AnnotationContentSemantics.hasContent(annotation.note) ? annotation.note : nil,
            field: "notePreview",
            profile: .preview,
            truncatedFields: &truncated
        )
        source = AnnotationPublicSourceResult(annotation, truncatedFields: &truncated)
        truncatedFields = uniqueAnnotationTruncatedFields(truncated)
    }
}

struct AnnotationDetailResult: Codable, Equatable, Sendable {
    let uuid: String?
    let localPK: Int64?
    let selectedText: String?
    let note: String?
    let createdAt: Date?
    let modifiedAt: Date?
    let hasHighlight: Bool
    let hasNote: Bool
    let color: String?
    let underline: Bool
    let source: AnnotationPublicSourceResult
    let chapterID: String?
    let bookURL: String?
    let truncatedFields: [String]

    init(_ annotation: SemanticAnnotation) {
        let stableUUID = PublicStableTokenPolicy.isEligible(annotation.uuid) ? annotation.uuid : nil
        uuid = stableUUID
        localPK = stableUUID == nil && LocalPKPolicy.isEligible(annotation.localPK) ? annotation.localPK : nil
        hasHighlight = annotation.hasHighlight
        hasNote = annotation.hasNote
        createdAt = annotation.createdAt
        modifiedAt = annotation.modifiedAt
        color = annotationColorName(annotation.style)
        underline = annotation.isUnderline == true

        var truncated = annotation.byteTruncatedFields.filter {
            $0 == "selectedText" || $0 == "note" || $0 == "location"
        }
        selectedText = boundedField(
            annotation.selectedText,
            field: "selectedText",
            profile: .detail,
            truncatedFields: &truncated
        )
        note = boundedField(
            annotation.note,
            field: "note",
            profile: .detail,
            truncatedFields: &truncated
        )
        source = AnnotationPublicSourceResult(annotation, truncatedFields: &truncated)
        chapterID = boundedField(
            annotation.chapterID,
            field: "chapterID",
            profile: .metadata,
            truncatedFields: &truncated
        )
        bookURL = source.bookAssetID.flatMap(Annotation.bookAppleBooksURL(assetID:))
        truncatedFields = uniqueAnnotationTruncatedFields(truncated)
    }
}

private func annotationColorName(_ style: Int64?) -> String? {
    switch style {
    case AnnotationColor.green.rawValue: "green"
    case AnnotationColor.blue.rawValue: "blue"
    case AnnotationColor.yellow.rawValue: "yellow"
    case AnnotationColor.pink.rawValue: "pink"
    case AnnotationColor.purple.rawValue: "purple"
    default: nil
    }
}

private func uniqueAnnotationTruncatedFields(_ fields: [String]) -> [String] {
    var unique: [String] = []
    unique.reserveCapacity(fields.count)
    for field in fields where unique.contains(field) == false { unique.append(field) }
    return unique
}

struct AnnotationCollectionResult: Codable, Equatable, Sendable {
    let items: [AnnotationResult]
    let limit: Int?
    let offset: Int

    init(semantic: [SemanticAnnotation], limit: Int?, offset: Int) {
        items = semantic.map { AnnotationResult($0) }
        self.limit = limit
        self.offset = offset
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

private func validateAnnotationPagination(limit: Int?, offset: Int) throws {
    if let limit, limit <= 0 {
        throw ValidationError("--limit must be positive.")
    }
    guard offset >= 0 else {
        throw ValidationError("--offset must be non-negative.")
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    values.first { value in
        guard let value else { return false }
        return value.isEmpty == false
    } ?? nil
}

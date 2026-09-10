import AppleBooksCore
import ArgumentParser
import Foundation

struct AnnotationsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "annotations",
        abstract: "Query and inspect Apple Books annotations.",
        subcommands: [
            AnnotationsListCommand.self,
            AnnotationsGetCommand.self,
            AnnotationsContextCommand.self,
            AnnotationsUpdateNoteCommand.self,
            AnnotationsDeleteCommand.self,
        ]
    )
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
            guard let row = try selector.resolveSemantic(in: books) else {
                throw CLIError.notFound("Annotation not found.")
            }
            return AnnotationDetailResult(row)
        }
    }
}

struct AnnotationsContextCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "context",
        abstract: "Resolve bounded context around one annotation."
    )

    @Argument(help: "Exact annotation UUID.")
    var uuid: String?

    @Option(name: .long, parsing: .unconditional, help: "Use an explicit local annotation primary key.")
    var pk: Int64?

    @Option(name: .long, parsing: .unconditional, help: "Context graphemes before the match (0 through 2000; default 300).")
    var before = 300

    @Option(name: .long, parsing: .unconditional, help: "Context graphemes after the match (0 through 2000; default 300).")
    var after = 300

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try output.writeJSON(try execute())
    }

    func execute() throws -> AnnotationContextResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: pk)
        guard (0...2_000).contains(before), (0...2_000).contains(after) else {
            throw ValidationError("--before and --after must be between 0 and 2000.")
        }
        return try CLIOperation.run {
            let books = try CLIContext(global: global).makeAppleBooks(
                dependencies: [.libraryRead, .annotationsRead, .configuration]
            )
            guard let result = try selector.resolveContext(
                in: books,
                charsBefore: before,
                charsAfter: after
            ) else {
                throw CLIError.notFound("Annotation not found.")
            }
            return AnnotationContextResult(result, requestedBefore: before, requestedAfter: after)
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
            return try MutationCommandResult(try selector.updateNote(note, in: books, syncCloud: sync))
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
            return try MutationCommandResult(try selector.delete(in: books, syncCloud: sync))
        }
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

struct AnnotationContextResult: Codable, Equatable, Sendable {
    let uuid: String?
    let localPK: Int64?
    let before: String
    let matched: String
    let after: String
    let leadingTruncated: Bool
    let trailingTruncated: Bool
    let truncatedFields: [String]

    init(
        _ result: SemanticAnnotationContextResult,
        requestedBefore: Int,
        requestedAfter: Int
    ) {
        let stableUUID = PublicStableTokenPolicy.isEligible(result.annotationUUID) ? result.annotationUUID : nil
        uuid = stableUUID
        localPK = stableUUID == nil && LocalPKPolicy.isEligible(result.annotationLocalPK)
            ? result.annotationLocalPK
            : nil

        let beforeProfile = annotationContextSideProfile(requestedGraphemes: requestedBefore)
        let afterProfile = annotationContextSideProfile(requestedGraphemes: requestedAfter)
        let boundedBefore = boundedContextBefore(result.context.before, profile: beforeProfile)
        let boundedMatched = BoundedTextPolicy.truncate(result.context.matched, profile: .detail)
        let boundedAfter = BoundedTextPolicy.truncate(result.context.after, profile: afterProfile)

        before = boundedBefore.value
        matched = boundedMatched.value ?? ""
        after = boundedAfter.value ?? ""
        leadingTruncated = result.context.leadingTruncated || boundedBefore.truncated
        trailingTruncated = result.context.trailingTruncated || boundedAfter.truncated

        var truncated: [String] = []
        if boundedBefore.truncated { truncated.append("before") }
        if boundedMatched.truncated { truncated.append("matched") }
        if boundedAfter.truncated { truncated.append("after") }
        truncatedFields = truncated
    }
}

private func annotationContextSideProfile(requestedGraphemes: Int) -> BoundedTextProfile {
    BoundedTextProfile(
        maximumGraphemes: requestedGraphemes,
        maximumUTF8Bytes: requestedGraphemes == 300 ? 4 * 1_024 : 16 * 1_024
    )
}

private func boundedContextBefore(
    _ value: String,
    profile: BoundedTextProfile
) -> (value: String, truncated: Bool) {
    guard value.count > profile.maximumGraphemes || value.utf8.count > profile.maximumUTF8Bytes else {
        return (value, false)
    }
    var reversed: [Character] = []
    reversed.reserveCapacity(min(value.count, profile.maximumGraphemes))
    var bytes = 0
    for character in value.reversed() {
        let characterBytes = character.utf8.count
        guard reversed.count < profile.maximumGraphemes,
              bytes <= profile.maximumUTF8Bytes - characterBytes else {
            break
        }
        reversed.append(character)
        bytes += characterBytes
    }
    return (String(reversed.reversed()), true)
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

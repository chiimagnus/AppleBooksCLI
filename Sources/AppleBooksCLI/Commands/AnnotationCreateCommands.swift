import AppleBooksCore
import ArgumentParser
import CryptoKit
import Darwin
import Foundation

struct AnnotationCreateInput: Decodable {
    struct Entry: Decodable {
        let text: String
        let chapterOrder: Int?
        let prefix: String?
        let suffix: String?
        let occurrence: Int?
        let color: String?
        let underline: Bool?
        let note: String?

        var nativeColor: AnnotationColor {
            AnnotationColorArgument(rawValue: color ?? "yellow")!.queryValue
        }
        var isUnderlined: Bool { underline ?? false }
    }

    let annotations: [Entry]
}

struct AnnotationCreateSnapshot {
    let input: AnnotationCreateInput
    let digest: String
}

// Shared by parsed-command copies: history hashes exactly the bounded bytes that execution consumes.
final class AnnotationCreateInputCache {
    private var cached: AnnotationCreateSnapshot?

    func load(_ path: String) throws -> AnnotationCreateSnapshot {
        if let cached { return cached }
        let fd: FileHandle
        do { fd = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)) }
        catch { throw CLIError.usageInvalid("Annotation input file is unavailable.") }
        defer { try? fd.close() }
        var info = stat()
        guard fstat(fd.fileDescriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= 8 * 1_024 * 1_024 else {
            throw CLIError.usageInvalid("Annotation input must be a regular JSON file, at most 8 MiB.")
        }
        let data: Data
        do { data = try fd.read(upToCount: 8 * 1_024 * 1_024 + 1) ?? Data() }
        catch { throw CLIError.usageInvalid("Annotation input file could not be read.") }
        guard data.isEmpty == false, data.count <= 8 * 1_024 * 1_024,
              data.count == Int(info.st_size) else {
            throw CLIError.usageInvalid("Annotation input was truncated or changed during reading.")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["annotations"],
              let records = object["annotations"] as? [[String: Any]],
              records.isEmpty == false, records.count <= 500 else {
            throw CLIError.usageInvalid("Annotation JSON requires 1 to 500 entries in `annotations`.")
        }
        let keys: Set<String> = [
            "text", "chapterOrder", "prefix", "suffix", "occurrence", "color", "underline", "note",
        ]
        for record in records {
            guard Set(record.keys).isSubset(of: keys),
                  let text = record["text"] as? String,
                  text.isEmpty == false,
                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  text.utf8.count <= 1_024 * 1_024,
                  (record["chapterOrder"] == nil || (record["chapterOrder"] as? Int ?? 0) > 0),
                  (record["occurrence"] == nil || (record["occurrence"] as? Int ?? 0) > 0),
                  (record["prefix"] == nil || record["prefix"] is String),
                  (record["suffix"] == nil || record["suffix"] is String),
                  (record["color"] == nil || (record["color"] as? String).flatMap(AnnotationColorArgument.init(rawValue:)) != nil),
                  (record["underline"] == nil || record["underline"] is Bool) else {
                throw CLIError.usageInvalid("Annotation entry contains invalid or unsupported fields.")
            }
            if let note = record["note"] as? String {
                guard note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      note.count <= 10_000, note.utf8.count <= 64 * 1_024 else {
                    throw CLIError.usageInvalid("Annotation note length is invalid.")
                }
            } else if let value = record["note"], !(value is NSNull) {
                throw CLIError.usageInvalid("Annotation note must be a string or null.")
            }
        }
        let parsed: AnnotationCreateInput
        do { parsed = try JSONDecoder().decode(AnnotationCreateInput.self, from: data) }
        catch { throw CLIError.usageInvalid("Annotation input has invalid field types.") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let snapshot = AnnotationCreateSnapshot(input: parsed, digest: digest)
        cached = snapshot
        return snapshot
    }
}

private func annotationCreateBookID(
    book: String?, bookPK: Int64?, books: AppleBooks
) throws -> String {
    let selector = try parseBookSelector(assetID: book, localPK: bookPK)
    guard let detail = try selector.resolveSemanticDetail(in: books),
          let assetID = detail.assetID, assetID.isEmpty == false else {
        throw CLIError.notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
    }
    return assetID
}

struct AnnotationCreatePreviewEntry: Encodable {
    let index: Int
    let status: String
    let chapterOrder: Int?
    let existingUUID: String?
    let candidateCount: Int?
    let recoveryHint: String?

    init(index: Int, preview: AnnotationCreationPreview) {
        self.index = index
        status = preview.status.rawValue
        chapterOrder = preview.chapterOrder
        existingUUID = preview.existingUUID
        candidateCount = nil
        recoveryHint = nil
    }

    init(index: Int, error: Error) throws {
        self.index = index
        chapterOrder = nil
        existingUUID = nil
        if let locator = error as? EPUBAnnotationLocatorError {
            switch locator {
            case let .ambiguous(count):
                status = "ambiguous"
                candidateCount = count
                recoveryHint = "Specify chapterOrder, prefix/suffix, or occurrence to locate one match."
            case .noMatch, .fragmentNotFound, .chapterNotFound:
                status = "missing"
                candidateCount = 0
                recoveryHint = "Check the current book text and chapter order."
            case .invalidText, .invalidOccurrence:
                status = "invalid"
                candidateCount = nil
                recoveryHint = "Provide nonempty text and a positive occurrence with chapterOrder."
            case .bookNotFound, .unsupportedSource, .invalidXHTML,
                 .ambiguousVisibility, .ambiguousSpine, .sourceChanged, .tooComplex:
                throw error
            }
        } else if let creation = error as? AnnotationCreateError, creation == .conflict {
            status = "conflict"
            candidateCount = nil
            recoveryHint = "Inspect the existing annotation at this position before editing it."
        } else {
            throw error
        }
    }
}

struct AnnotationCreatePreviewResult: Encodable {
    let status: String
    let complete: Bool
    let itemCount: Int
    let items: [AnnotationCreatePreviewEntry]
}

struct AnnotationsRepairSyncCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "repair-sync",
        abstract: "Reproject an existing committed annotation UUID without inserting a new local highlight."
    )
    @Argument(help: "Exact existing annotation UUID.") var uuid: String
    @OptionGroup var global: GlobalOptions

    var historyOperation: String { "annotations.repair-sync" }
    func historyRequest() throws -> OperationHistoryRequest {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: nil)
        return OperationHistoryRequest(selector: selector.historySelector)
    }
    mutating func run() throws { try run(output: .standard) }
    func run(output: CLIOutput) throws { try output.writeJSON(try execute()) }
    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        try output.writeJSON(try execute(historySink: sink))
    }
    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> AnnotationProjectionRepairResult {
        let selector = try parseAnnotationSelector(uuid: uuid, localPK: nil)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(
                dependencies: [.annotationsRead, .annotationWrite]
            )
            guard case let .uuid(stableUUID) = selector else {
                throw CLIError.usageInvalid("Repair requires an exact annotation UUID.")
            }
            let result = try books.repairAnnotationProjection(uuid: stableUUID)
            historySink?.record(.repairProjection(result))
            return result
        }
    }
}

struct AnnotationsPreviewCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "preview",
        abstract: "Validate EPUB text selections and existing highlights without writing anything."
    )
    @Option(name: .long, help: "Exact Apple Books book asset ID.") var book: String?
    @Option(name: .customLong("book-pk"), help: "Explicit local book primary key.") var bookPK: Int64?
    @Option(name: .long, help: "Path to bounded JSON annotation input.") var input: String
    @OptionGroup var global: GlobalOptions
    private var cache = AnnotationCreateInputCache()
    private enum CodingKeys: String, CodingKey { case book, bookPK, input, global }

    mutating func run() throws { try run(output: .standard) }
    func run(output: CLIOutput) throws { try output.writeJSON(try execute()) }

    func execute(using injectedBooks: AppleBooks? = nil) throws -> AnnotationCreatePreviewResult {
        let snapshot = try cache.load(input)
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(
                dependencies: [.libraryRead, .annotationsRead, .configuration]
            )
            let assetID = try annotationCreateBookID(book: book, bookPK: bookPK, books: books)
            let values = try snapshot.input.annotations.enumerated().map { index, record in
                do {
                    let preview = try books.previewAnnotation(
                        assetID: assetID, text: record.text,
                        chapterOrder: record.chapterOrder, prefix: record.prefix,
                        suffix: record.suffix, occurrence: record.occurrence,
                        note: record.note, color: record.nativeColor, underline: record.isUnderlined
                    )
                    return AnnotationCreatePreviewEntry(index: index, preview: preview)
                } catch {
                    return try AnnotationCreatePreviewEntry(index: index, error: error)
                }
            }
            let complete = values.allSatisfy { $0.status == "ready" || $0.status == "already_exists" }
            return AnnotationCreatePreviewResult(
                status: complete ? "ready" : "needs_review",
                complete: complete, itemCount: values.count, items: values
            )
        }
    }
}

struct AnnotationsCreateCommand: ParsableCommand, CLIOutputRunnable, OperationHistoryRecordable {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create one native EPUB highlight from a validated JSON input."
    )
    @Option(name: .long, help: "Exact Apple Books book asset ID.") var book: String?
    @Option(name: .customLong("book-pk"), help: "Explicit local book primary key.") var bookPK: Int64?
    @Option(name: .long, help: "Path to bounded JSON annotation input.") var input: String
    @Flag(name: .long, help: "Wait for acknowledgement on this Mac after creation.") var sync = false
    @OptionGroup var global: GlobalOptions
    private var cache = AnnotationCreateInputCache()
    private enum CodingKeys: String, CodingKey { case book, bookPK, input, sync, global }

    var historyOperation: String { "annotations.create" }
    func historyRequest() throws -> OperationHistoryRequest {
        let selector = try parseBookSelector(assetID: book, localPK: bookPK)
        let snapshot = try cache.load(input)
        guard snapshot.input.annotations.count == 1 else {
            throw CLIError.usageInvalid("Create currently requires exactly one annotation entry.")
        }
        return OperationHistoryRequest(
            selector: selector.addingHistoryIdentity(to: OperationHistorySelector()),
            syncRequested: sync, inputDigest: snapshot.digest
        )
    }
    mutating func run() throws { try run(output: .standard) }
    func run(output: CLIOutput) throws { try output.writeJSON(try execute()) }
    func runForHistory(output: CLIOutput, sink: OperationHistoryCompletionSink) throws {
        try output.writeJSON(try execute(historySink: sink))
    }
    func execute(
        using injectedBooks: AppleBooks? = nil,
        historySink: OperationHistoryCompletionSink? = nil
    ) throws -> AnnotationMutationCommandResult {
        let snapshot = try cache.load(input)
        guard snapshot.input.annotations.count == 1,
              let record = snapshot.input.annotations.first else {
            throw CLIError.usageInvalid("Create currently requires exactly one annotation entry.")
        }
        return try CLIOperation.run {
            let books = try injectedBooks ?? CLIContext(global: global).makeAppleBooks(
                dependencies: [.libraryRead, .annotationsRead, .configuration, .annotationWrite]
            )
            let assetID = try annotationCreateBookID(book: book, bookPK: bookPK, books: books)
            let result = try books.createAnnotation(
                assetID: assetID, text: record.text, chapterOrder: record.chapterOrder,
                prefix: record.prefix, suffix: record.suffix, occurrence: record.occurrence,
                note: record.note, color: record.nativeColor, underline: record.isUnderlined,
                syncCloud: sync
            )
            historySink?.record(.mutation(
                result, inverse: .annotationState(result, operation: "annotations.delete")
            ))
            let selector: AnnotationSelector = result.stableID.map(AnnotationSelector.uuid)
                ?? .localPK(result.localPK ?? 0)
            return AnnotationMutationCommandResult(result, selector: selector)
        }
    }
}

import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("CursorPaginationTests")
struct CursorPaginationTests {
    @Test
    func firstMiddleLastPagesUseOpaqueKeysetAndAllowLimitChanges() throws {
        let owner = SyntheticOwner(values: Array(1...45))

        let first = try owner.page(limit: nil)
        #expect(first.items == Array(1...20))
        #expect(first.hasMore)
        #expect(first.nextCursor != nil)
        #expect(first.total == 45)

        let middle = try owner.page(limit: 20, cursor: first.nextCursor)
        #expect(middle.items == Array(21...40))
        #expect(middle.hasMore)

        let last = try owner.page(limit: 100, cursor: middle.nextCursor)
        #expect(last.items == Array(41...45))
        #expect(last.hasMore == false)
        #expect(last.nextCursor == nil)

        let one = try owner.page(limit: 1)
        #expect(one.items == [1])
        let remainder = try owner.page(limit: 100, cursor: one.nextCursor)
        #expect(remainder.items == Array(2...45))
        #expect(remainder.hasMore == false)
    }

    @Test
    func limitsAndCursorGrammarFailAtStableBoundaries() throws {
        let owner = SyntheticOwner(values: Array(1...3))
        #expect(throws: CursorPaginationError.limitOutOfRange) { _ = try owner.page(limit: 0) }
        #expect(throws: CursorPaginationError.limitOutOfRange) { _ = try owner.page(limit: 101) }
        #expect(try owner.page(limit: 1).items == [1])
        #expect(try owner.page(limit: 100).items == [1, 2, 3])

        for token in [
            "",
            String(repeating: "A", count: 4_096),
            String(repeating: "A", count: 4_097),
            "abc=",
            "abc/def",
            "游标",
        ] {
            #expect(throws: CursorPaginationError.invalidCursor) {
                _ = try owner.page(cursor: token)
            }
        }

        let valid = try #require(try owner.page(limit: 1).nextCursor)
        let unknownVersion = try tokenByReplacingVersion(valid, with: 99)
        #expect(throws: CursorPaginationError.invalidCursor) {
            _ = try owner.page(cursor: unknownVersion)
        }
    }

    @Test
    func fingerprintCanonicalizationIsFieldOrderIndependent() throws {
        let first = try CursorQueryFingerprint.make(
            kind: "books-search",
            fields: [
                CursorFingerprintField("order", .string("title-asc")),
                CursorFingerprintField("field", .string("all")),
            ]
        )
        let second = try CursorQueryFingerprint.make(
            kind: "books-search",
            fields: [
                CursorFingerprintField("field", .string("all")),
                CursorFingerprintField("order", .string("title-asc")),
            ]
        )
        #expect(first == second)
    }

    @Test
    func cursorBindsKindFilterAndOrderButNotLimit() throws {
        let owner = SyntheticOwner(values: Array(1...30))
        let token = try #require(try owner.page(limit: 1, filter: "odd", order: "asc").nextCursor)

        #expect(try owner.page(limit: 100, cursor: token, filter: "odd", order: "asc").items == Array(stride(from: 3, through: 29, by: 2)))
        #expect(throws: CursorPaginationError.filterMismatch) {
            _ = try owner.page(cursor: token, filter: "all", order: "asc")
        }
        #expect(throws: CursorPaginationError.filterMismatch) {
            _ = try owner.page(cursor: token, filter: "odd", order: "desc")
        }
        #expect(throws: CursorPaginationError.filterMismatch) {
            _ = try owner.page(cursor: token, filter: "odd", order: "asc", kind: "other-command")
        }
    }

    @Test
    func sameInputsProduceDeterministicOpaqueTokenWithoutPrivateQueryMaterial() throws {
        let secret = "secret-search-text-DO-NOT-EMBED"
        let privatePath = "/private/example/library.sqlite"
        let owner = SyntheticOwner(values: Array(1...25), generationSalt: privatePath)

        let first = try owner.page(limit: 20, search: secret)
        let repeated = try owner.page(limit: 20, search: secret)
        let token = try #require(first.nextCursor)
        #expect(token == repeated.nextCursor)

        let decoded = try decodeBase64URL(token)
        #expect(decoded.range(of: Data(secret.utf8)) == nil)
        #expect(decoded.range(of: Data(privatePath.utf8)) == nil)
        #expect(token.contains(secret) == false)
        #expect(token.contains(privatePath) == false)
    }

    @Test
    func tokenDoesNotEmbedDatabaseConfigSourcePathsOrSearchText() throws {
        let root = temporaryDirectory().appendingPathComponent("private-cursor-root-DO-NOT-EMBED", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = root.appendingPathComponent("private-library.sqlite")
        let config = root.appendingPathComponent("private-config.json")
        let sources = root.appendingPathComponent("private-sources", isDirectory: true)
        let source = sources.appendingPathComponent("private-book.epub")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("db".utf8).write(to: library)
        try Data("config".utf8).write(to: config)
        try Data("source".utf8).write(to: source)

        var directory = try CursorDirectoryGenerationBuilder(label: "source", rootURL: sources)
        try directory.add(relativeName: source.lastPathComponent, fileURL: source)
        let generation = try CursorGeneration.compose([
            try .sqlite(label: "library", databaseURL: library),
            try .regularFile(label: "config", url: config),
            try directory.finish(),
        ])
        let search = "private-search-text-DO-NOT-EMBED"
        let fingerprint = try CursorQueryFingerprint.make(
            kind: "books-search",
            fields: [CursorFingerprintField("search", .string(search))]
        )
        let session = try CursorPaginationSession(cursor: nil, fingerprint: fingerprint, generation: generation)
        let page = try makeCursorPage(
            candidates: [1, 2],
            limit: 1,
            session: session,
            afterGeneration: generation,
            locator: { try .rowID(Int64($0)) }
        )
        let token = try #require(page.nextCursor)
        #expect(token.utf8.count < 4_096)
        let decoded = try decodeBase64URL(token)
        for privateValue in [search, root.path, library.path, config.path, source.path] {
            #expect(decoded.range(of: Data(privateValue.utf8)) == nil)
            #expect(token.contains(privateValue) == false)
        }
    }

    @Test
    func dataGenerationChangesRejectOldCursorAndMidQueryChangesRejectPage() throws {
        let owner = SyntheticOwner(values: Array(1...25))
        let token = try #require(try owner.page(limit: 5).nextCursor)

        let changed = SyntheticOwner(values: Array(1...26))
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try changed.page(limit: 5, cursor: token)
        }

        let locatorToken = try #require(try SyntheticOwner(values: [1, 2, 3], generationIncludesValues: false).page(limit: 1).nextCursor)
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try SyntheticOwner(values: [2, 3], generationIncludesValues: false).page(limit: 1, cursor: locatorToken)
        }

        let fingerprint = try CursorQueryFingerprint.make(kind: "synthetic", fields: [])
        let beforeComponent = try CursorGenerationComponent.synthetic(label: "data", value: "before")
        let afterComponent = try CursorGenerationComponent.synthetic(label: "data", value: "after")
        let before = try CursorGeneration.compose([beforeComponent])
        let after = try CursorGeneration.compose([afterComponent])
        let session = try CursorPaginationSession(cursor: nil, fingerprint: fingerprint, generation: before)
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try makeCursorPage(
                candidates: [1, 2],
                limit: 1,
                session: session,
                afterGeneration: after,
                locator: { try .rowID(Int64($0)) }
            )
        }
    }

    @Test
    func compositeGenerationIsLabelOrderedAndEveryParticipatingSourceCanInvalidateIt() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        let config = root.appendingPathComponent("config.json")
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        let source = sources.appendingPathComponent("one.epub")
        let unrelated = root.appendingPathComponent("unrelated.txt")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("library".utf8).write(to: library)
        try Data("annotations".utf8).write(to: annotations)
        try Data("config".utf8).write(to: config)
        try Data("source".utf8).write(to: source)
        try Data("outside".utf8).write(to: unrelated)

        let baselineComponents = try components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)
        let baseline = try CursorGeneration.compose(baselineComponents)
        #expect(try CursorGeneration.compose(baselineComponents.reversed()) == baseline)

        try rewriteWithDistinctMetadata(library, contents: "library-2")
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) != baseline)
        try rewriteWithDistinctMetadata(library, contents: "library")
        let reset = try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source))

        try rewriteWithDistinctMetadata(annotations, contents: "annotations-2")
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) != reset)
        try rewriteWithDistinctMetadata(annotations, contents: "annotations")
        let reset2 = try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source))

        try rewriteWithDistinctMetadata(config, contents: "config-2")
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) != reset2)
        try FileManager.default.removeItem(at: config)
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) != reset2)
        try Data("config".utf8).write(to: config)
        let reset3 = try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source))

        try rewriteWithDistinctMetadata(source, contents: "source-2")
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) != reset3)
        let beforeUnrelated = try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source))
        try rewriteWithDistinctMetadata(unrelated, contents: "outside-2")
        #expect(try CursorGeneration.compose(components(library: library, annotations: annotations, config: config, sourceRoot: sources, source: source)) == beforeUnrelated)
    }

    @Test
    func directoryGenerationIsStreamingOrderIndependentAndRetainsNoNames() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var forward = try CursorDirectoryGenerationBuilder(label: "pdf-directory", rootURL: root)
        var reverse = try CursorDirectoryGenerationBuilder(label: "pdf-directory", rootURL: root)
        let metadata = CursorFileMetadata(
            device: 1,
            inode: 2,
            size: 3,
            modificationSeconds: 4,
            modificationNanoseconds: 5
        )

        for index in 0..<10_000 {
            try forward.add(relativeName: "candidate-\(index).pdf", metadata: metadata)
        }
        for index in (0..<10_000).reversed() {
            try reverse.add(relativeName: "candidate-\(index).pdf", metadata: metadata)
        }
        #expect(forward.retainedCandidateNameCount == 0)
        #expect(reverse.retainedCandidateNameCount == 0)
        #expect(try forward.finish() == reverse.finish())

        var invalid = try CursorDirectoryGenerationBuilder(label: "pdf-directory", rootURL: root)
        #expect(throws: CursorPaginationError.internalContractFailure) {
            try invalid.add(relativeName: "../escape.pdf", metadata: metadata)
        }
        #expect(throws: CursorPaginationError.internalContractFailure) {
            try invalid.add(relativeName: String(repeating: "x", count: 4_097), metadata: metadata)
        }

        let external = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("outside".utf8).write(to: external)
        #expect(throws: CursorPaginationError.internalContractFailure) {
            try invalid.add(relativeName: "outside.pdf", fileURL: external)
        }
    }

    @Test
    func sqliteGenerationTracksMainAndWalButIgnoresShmMetadata() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("wal.sqlite")
        var handle: OpaquePointer?
        #expect(sqlite3_open(database.path, &handle) == SQLITE_OK)
        let db = try #require(handle)
        defer { sqlite3_close_v2(db) }
        try exec(db, "PRAGMA journal_mode=WAL")
        try exec(db, "PRAGMA wal_autocheckpoint=0")
        try exec(db, "CREATE TABLE values_table(value INTEGER)")
        try exec(db, "INSERT INTO values_table VALUES(1)")

        let initial = try CursorGenerationComponent.sqlite(label: "library", databaseURL: database)
        let shm = URL(fileURLWithPath: database.path + "-shm")
        if FileManager.default.fileExists(atPath: shm.path) {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 123)], ofItemAtPath: shm.path)
            #expect(try CursorGenerationComponent.sqlite(label: "library", databaseURL: database) == initial)
        }

        try exec(db, "INSERT INTO values_table VALUES(2)")
        let afterCommit = try CursorGenerationComponent.sqlite(label: "library", databaseURL: database)
        #expect(afterCommit != initial)

        let readOnly = try SQLiteConnection.readOnly(path: database.path)
        try readOnly.close()
        #expect(try CursorGenerationComponent.sqlite(label: "library", databaseURL: database) == afterCommit)

        try exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
        let afterCheckpoint = try CursorGenerationComponent.sqlite(label: "library", databaseURL: database)
        #expect(afterCheckpoint != afterCommit)
    }

    @Test
    func sqliteGenerationTreatsWalAppearanceDeletionAndReplacementAsChanges() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("synthetic.sqlite")
        let wal = URL(fileURLWithPath: database.path + "-wal")
        try Data("main".utf8).write(to: database)

        let withoutWal = try CursorGenerationComponent.sqlite(label: "library", databaseURL: database)
        try Data("wal-one".utf8).write(to: wal)
        let withWal = try CursorGenerationComponent.sqlite(label: "library", databaseURL: database)
        #expect(withWal != withoutWal)

        try FileManager.default.removeItem(at: wal)
        #expect(try CursorGenerationComponent.sqlite(label: "library", databaseURL: database) == withoutWal)

        try Data("wal-two-distinct".utf8).write(to: wal)
        #expect(try CursorGenerationComponent.sqlite(label: "library", databaseURL: database) != withWal)
    }

    private func components(
        library: URL,
        annotations: URL,
        config: URL,
        sourceRoot: URL,
        source: URL
    ) throws -> [CursorGenerationComponent] {
        var directory = try CursorDirectoryGenerationBuilder(label: "source-directory", rootURL: sourceRoot)
        try directory.add(relativeName: source.lastPathComponent, fileURL: source)
        return [
            try .sqlite(label: "library", databaseURL: library),
            try .sqlite(label: "annotations", databaseURL: annotations),
            try .regularFile(label: "config", url: config, optional: true),
            try directory.finish(),
        ]
    }

    private func tokenByReplacingVersion(_ token: String, with version: UInt8) throws -> String {
        var data = try decodeBase64URL(token)
        guard data.count > 4 else { throw CursorPaginationError.invalidCursor }
        data[4] = version
        return encodeBase64URL(data)
    }

    private func decodeBase64URL(_ token: String) throws -> Data {
        var encoded = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { throw CursorPaginationError.invalidCursor }
        return data
    }

    private func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func rewriteWithDistinctMetadata(_ url: URL, contents: String) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func exec(_ handle: OpaquePointer, _ sql: String) throws {
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
    }

    private func temporaryDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private struct SyntheticOwner {
    let values: [Int]
    var generationSalt = "generation"
    var generationIncludesValues = true

    func page(
        limit: Int? = nil,
        cursor: String? = nil,
        filter: String = "all",
        order: String = "asc",
        kind: String = "synthetic-command",
        search: String = ""
    ) throws -> CursorPage<Int> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        let fingerprint = try CursorQueryFingerprint.make(
            kind: kind,
            fields: [
                CursorFingerprintField("filter", .string(filter)),
                CursorFingerprintField("order", .string(order)),
                CursorFingerprintField("search", .string(search)),
            ]
        )
        let generationValue = generationIncludesValues
            ? generationSalt + ":" + values.map(String.init).joined(separator: ",")
            : generationSalt
        let generationComponent = try CursorGenerationComponent.synthetic(
            label: "values",
            value: generationValue
        )
        let generation = try CursorGeneration.compose([generationComponent])
        let session = try CursorPaginationSession(cursor: cursor, fingerprint: fingerprint, generation: generation)

        var selected: [Int]
        switch filter {
        case "all": selected = values
        case "odd": selected = values.filter { !$0.isMultiple(of: 2) }
        case "even": selected = values.filter { $0.isMultiple(of: 2) }
        default: selected = []
        }
        switch order {
        case "asc": selected.sort()
        case "desc": selected.sort(by: >)
        default: break
        }

        if let locator = session.locator {
            guard let raw = locator.words.first else { throw CursorPaginationError.invalidCursor }
            let last = Int64(bitPattern: raw)
            guard let index = selected.firstIndex(where: { Int64($0) == last }) else {
                throw CursorPaginationError.staleCursor
            }
            selected = Array(selected.dropFirst(index + 1))
        }
        let candidates = Array(selected.prefix(effectiveLimit + 1))
        return try makeCursorPage(
            candidates: candidates,
            limit: effectiveLimit,
            total: values.count,
            session: session,
            afterGeneration: generation,
            locator: { try .rowID(Int64($0)) }
        )
    }
}

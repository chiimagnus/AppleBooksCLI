import AppleBooksCore
import CryptoKit
import Darwin
import Foundation

enum OperationHistoryStoreError: Error, Equatable {
    case unavailable
    case invalidID
}

enum OperationHistoryStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
    case incomplete
}

struct OperationHistorySelector: Codable, Equatable, Sendable {
    let annotationUUID: String?
    let annotationLocalPK: Int64?
    let collectionID: String?
    let collectionLocalPK: Int64?
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let backupID: String?

    init(
        annotationUUID: String? = nil,
        annotationLocalPK: Int64? = nil,
        collectionID: String? = nil,
        collectionLocalPK: Int64? = nil,
        bookAssetID: String? = nil,
        bookLocalPK: Int64? = nil,
        backupID: String? = nil
    ) {
        self.annotationUUID = annotationUUID
        self.annotationLocalPK = annotationLocalPK
        self.collectionID = collectionID
        self.collectionLocalPK = collectionLocalPK
        self.bookAssetID = bookAssetID
        self.bookLocalPK = bookLocalPK
        self.backupID = backupID
    }
}

struct OperationHistoryNoteAction: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case set
        case clear
    }

    let kind: Kind
    let text: String?

    static func set(_ text: String? = nil) -> Self { Self(kind: .set, text: text) }
    static let clear = Self(kind: .clear, text: nil)
}

struct OperationHistoryRequest: Codable, Equatable, Sendable {
    let available: Bool
    let selector: OperationHistorySelector?
    let noteAction: OperationHistoryNoteAction?
    let title: String?
    let syncRequested: Bool?

    static let unavailable = Self(
        available: false,
        selector: nil,
        noteAction: nil,
        title: nil,
        syncRequested: nil
    )

    init(
        available: Bool = true,
        selector: OperationHistorySelector? = nil,
        noteAction: OperationHistoryNoteAction? = nil,
        title: String? = nil,
        syncRequested: Bool? = nil
    ) {
        self.available = available
        self.selector = selector
        self.noteAction = noteAction
        self.title = title
        self.syncRequested = syncRequested
    }
}

struct OperationHistoryResult: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case mutation
        case restore
        case sync
        case unavailable
    }

    let kind: Kind
    let committed: Bool?
    let changed: Bool?
    let acknowledgementRequested: Bool?
    let acknowledged: Bool?
    let verified: Bool?
    let collectionPendingBefore: Int?
    let annotationPendingBefore: Int?
    let warningCodes: [String]

    static let unavailable = Self(
        kind: .unavailable,
        committed: nil,
        changed: nil,
        acknowledgementRequested: nil,
        acknowledged: nil,
        verified: nil,
        collectionPendingBefore: nil,
        annotationPendingBefore: nil,
        warningCodes: []
    )

    var withoutWarnings: Self {
        Self(
            kind: kind,
            committed: committed,
            changed: changed,
            acknowledgementRequested: acknowledgementRequested,
            acknowledged: acknowledged,
            verified: verified,
            collectionPendingBefore: collectionPendingBefore,
            annotationPendingBefore: annotationPendingBefore,
            warningCodes: []
        )
    }
}

struct OperationHistoryInverse: Codable, Equatable, Sendable {
    let available: Bool
    let operation: String?
    let selector: OperationHistorySelector?
    let noteAction: OperationHistoryNoteAction?
    let title: String?

    static let unavailable = Self(
        available: false,
        operation: nil,
        selector: nil,
        noteAction: nil,
        title: nil
    )

    static func annotationState(_ result: MutationResult, operation: String) -> Self {
        guard result.changed,
              let uuid = result.stableID,
              PublicStableTokenPolicy.isEligible(uuid) else {
            return .unavailable
        }
        return Self(
            available: true,
            operation: operation,
            selector: OperationHistorySelector(annotationUUID: uuid),
            noteAction: nil,
            title: nil
        )
    }

    static func annotationNote(_ result: MutationResult) -> Self {
        guard result.changed,
              let uuid = result.stableID,
              PublicStableTokenPolicy.isEligible(uuid),
              let effect = result.historyEffect,
              case let .annotationNote(previous) = effect else {
            return .unavailable
        }
        return Self(
            available: true,
            operation: "annotations.update-note",
            selector: OperationHistorySelector(annotationUUID: uuid),
            noteAction: previous.map(OperationHistoryNoteAction.set) ?? .clear,
            title: nil
        )
    }

    static func collectionRename(_ result: MutationResult) -> Self {
        guard result.changed,
              let collectionID = result.stableID,
              PublicStableTokenPolicy.isEligible(collectionID),
              let effect = result.historyEffect,
              case let .collectionTitle(previous) = effect else {
            return .unavailable
        }
        return Self(
            available: true,
            operation: "collections.rename",
            selector: OperationHistorySelector(collectionID: collectionID),
            noteAction: nil,
            title: previous
        )
    }

    static func membership(_ result: MutationResult, operation: String) -> Self {
        guard result.changed,
              let collectionID = result.stableID,
              PublicStableTokenPolicy.isEligible(collectionID),
              let bookAssetID = result.relatedStableID,
              PublicStableTokenPolicy.isEligible(bookAssetID) else {
            return .unavailable
        }
        return Self(
            available: true,
            operation: operation,
            selector: OperationHistorySelector(collectionID: collectionID, bookAssetID: bookAssetID),
            noteAction: nil,
            title: nil
        )
    }
}

struct OperationHistoryCompletion: Equatable, Sendable {
    let result: OperationHistoryResult
    let inverse: OperationHistoryInverse
}

final class OperationHistoryCompletionSink {
    private(set) var completion: OperationHistoryCompletion?

    func record(_ completion: OperationHistoryCompletion) {
        self.completion = completion
    }
}

extension OperationHistoryCompletion {
    static func mutation(_ result: MutationResult, inverse: OperationHistoryInverse = .unavailable) -> Self {
        Self(
            result: OperationHistoryResult(
                kind: .mutation,
                committed: result.committed,
                changed: result.changed,
                acknowledgementRequested: result.acknowledgementRequested,
                acknowledged: result.acknowledged,
                verified: nil,
                collectionPendingBefore: nil,
                annotationPendingBefore: nil,
                warningCodes: Array(result.warnings.prefix(100).map(\.rawValue))
            ),
            inverse: inverse
        )
    }

    static func restore(_ result: RestoreResult) -> Self {
        Self(
            result: OperationHistoryResult(
                kind: .restore,
                committed: result.restoreApplied,
                changed: result.restoreApplied,
                acknowledgementRequested: nil,
                acknowledged: nil,
                verified: result.verified,
                collectionPendingBefore: nil,
                annotationPendingBefore: nil,
                warningCodes: Array(result.warnings.prefix(100).map(\.rawValue))
            ),
            inverse: .unavailable
        )
    }

    static func sync(_ summary: CloudSyncSummary) -> Self {
        Self(
            result: OperationHistoryResult(
                kind: .sync,
                committed: nil,
                changed: summary.collectionPendingBefore > 0 || summary.annotationPendingBefore > 0,
                acknowledgementRequested: true,
                acknowledged: summary.acknowledged,
                verified: nil,
                collectionPendingBefore: summary.collectionPendingBefore,
                annotationPendingBefore: summary.annotationPendingBefore,
                warningCodes: summary.warnings.map(\.rawValue)
            ),
            inverse: .unavailable
        )
    }
}

struct OperationHistoryRecord: Equatable, Sendable {
    let id: String
    let operation: String
    let request: OperationHistoryRequest
    let startedAt: Date
    let completedAt: Date?
    let exitCode: Int32?
    let result: OperationHistoryResult?
    let inverse: OperationHistoryInverse
    let status: OperationHistoryStatus

    fileprivate let fileName: String
}

struct OperationHistoryToken: Equatable, Sendable {
    let id: String
    let startedAt: Date
    fileprivate let fileName: String
}

struct OperationHistorySummaryRecord: Equatable, Sendable {
    let id: String
    let operation: String
    let startedAt: Date
    let completedAt: Date?
    let exitCode: Int32?
    let status: OperationHistoryStatus
}

struct OperationHistoryStore: Sendable {
    static let retentionInterval: TimeInterval = 24 * 60 * 60

    static let schemaVersion = 2
    private static let lockFileName = ".lock"
    private static let temporaryPrefix = ".operation-history-"
    private static let temporarySuffix = ".tmp"
    private static let directoryMode = mode_t(S_IRWXU)
    private static let fileMode = mode_t(S_IRUSR | S_IWUSR)
    private static let lineReadChunkSize = 8 * 1_024
    private static let eventByteCap = 256 * 1_024
    private static let legacyBufferedLineByteCap = eventByteCap
    private static let processLock = NSLock()

    private let root: URL
    private let now: @Sendable () -> Date
    private let timeZone: @Sendable () -> TimeZone
    private let observeListCandidateCount: @Sendable (Int) -> Void
    private let observeLineBufferedBytes: @Sendable (Int) -> Void
    private let observeMigrationWarning: @Sendable () -> Void

    init(
        root: URL = Self.defaultRoot(),
        now: @escaping @Sendable () -> Date = Date.init,
        timeZone: @escaping @Sendable () -> TimeZone = { .current },
        observeListCandidateCount: @escaping @Sendable (Int) -> Void = { _ in },
        observeLineBufferedBytes: @escaping @Sendable (Int) -> Void = { _ in },
        observeMigrationWarning: @escaping @Sendable () -> Void = {}
    ) {
        let standardized = root.standardizedFileURL
        let canonicalParent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        self.root = canonicalParent.appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
        self.now = now
        self.timeZone = timeZone
        self.observeListCandidateCount = observeListCandidateCount
        self.observeLineBufferedBytes = observeLineBufferedBytes
        self.observeMigrationWarning = observeMigrationWarning
    }

    static func defaultRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AppleBooksCLI/history", isDirectory: true)
    }

    func begin(operation: String, request: OperationHistoryRequest) throws -> OperationHistoryToken {
        guard operation.isEmpty == false else { throw OperationHistoryStoreError.unavailable }
        let startedAt = Self.historyTimestamp(now())
        let result = try withLockedRoot(createIfMissing: true) { rootFD in
            try pruneWholeExpiredDateFiles(rootFD: rootFD, reference: startedAt)
            let id = UUID().uuidString.lowercased()
            let fileName = Self.dateFileName(for: startedAt, timeZone: timeZone())
            let event = OperationHistoryEvent.started(
                id: id,
                operation: operation,
                request: request,
                startedAt: startedAt
            )
            try append(event, to: fileName, rootFD: rootFD)
            return OperationHistoryToken(id: id, startedAt: startedAt, fileName: fileName)
        }
        guard case let .value(token) = result else { throw OperationHistoryStoreError.unavailable }
        return token
    }

    func complete(
        _ token: OperationHistoryToken,
        exitCode: Int32,
        completion: OperationHistoryCompletion?
    ) throws {
        let completedAt = Self.historyTimestamp(now())
        let cutoff = completedAt.addingTimeInterval(-Self.retentionInterval)
        if token.startedAt < cutoff {
            _ = try withLockedRoot(createIfMissing: false) { rootFD in
                try prune(rootFD: rootFD, reference: completedAt)
            }
            return
        }

        let result = try withLockedRoot(createIfMissing: false) { rootFD in
            guard let record = try targetRecord(id: token.id, fileName: token.fileName, rootFD: rootFD),
                  record.status == .incomplete,
                  record.startedAt == token.startedAt else {
                throw OperationHistoryStoreError.unavailable
            }
            let event = try Self.boundedCompletionEvent(
                id: token.id,
                completedAt: completedAt,
                exitCode: exitCode,
                completion: completion
            )
            try append(event, to: token.fileName, rootFD: rootFD)
        }
        guard case .value = result else { throw OperationHistoryStoreError.unavailable }
    }

    func listPage(limit: Int? = nil, cursor: String? = nil) throws -> CursorPage<OperationHistorySummaryRecord> {
        let effectiveLimit = try resolvedCursorPageLimit(limit)
        try validateCursorInputSyntax(cursor)
        let reference = Self.historyTimestamp(now())
        let result = try withLockedRoot(createIfMissing: false) { rootFD in
            try prune(rootFD: rootFD, reference: reference)
            let beforeGeneration = try historyGeneration(rootFD: rootFD)
            let fingerprint = try CursorQueryFingerprint.make(
                kind: "history.list",
                fields: [CursorFingerprintField("order.version", .unsigned(1))]
            )
            let session = try CursorPaginationSession(
                cursor: cursor,
                fingerprint: fingerprint,
                generation: beforeGeneration
            )
            let anchor = try Self.historyAnchor(from: session.locator)
            var anchorFound = anchor == nil
            var candidates: [HistoryListCandidate] = []
            candidates.reserveCapacity(effectiveLimit + 1)

            try forEachDateFile(rootFD: rootFD) { fileName in
                try forEachStoredLine(fileName, rootFD: rootFD) { line in
                    let event = line.event
                    switch event.kind {
                    case .started:
                        guard let operation = event.operation, let startedAt = event.startedAt else {
                            throw OperationHistoryStoreError.unavailable
                        }
                        let key = HistoryAnchor(startedAt: startedAt, id: event.id)
                        if key == anchor { anchorFound = true }
                        guard Self.isAfter(key, anchor: anchor) else { return }
                        try Self.retainHistoryCandidate(
                            HistoryListCandidate(
                                id: event.id,
                                operation: operation,
                                startedAt: startedAt,
                                completedAt: nil,
                                exitCode: nil
                            ),
                            maximumCount: effectiveLimit + 1,
                            in: &candidates
                        )
                        observeListCandidateCount(candidates.count)
                    case .completed:
                        guard let index = candidates.firstIndex(where: { $0.id == event.id }) else { return }
                        guard candidates[index].completedAt == nil,
                              let completedAt = event.completedAt,
                              let exitCode = event.exitCode else {
                            throw OperationHistoryStoreError.unavailable
                        }
                        candidates[index].completedAt = completedAt
                        candidates[index].exitCode = exitCode
                    }
                }
            }
            guard anchorFound else { throw CursorPaginationError.staleCursor }
            let afterGeneration = try historyGeneration(rootFD: rootFD)
            return try makeCursorPage(
                candidates: candidates.map(\.summary),
                limit: effectiveLimit,
                session: session,
                afterGeneration: afterGeneration,
                locator: Self.historyLocator
            )
        }
        switch result {
        case .missing:
            if cursor != nil { throw CursorPaginationError.staleCursor }
            return CursorPage(items: [], nextCursor: nil, hasMore: false)
        case let .value(page):
            return page
        }
    }

    func get(id: String) throws -> OperationHistoryRecord? {
        guard Self.isCanonicalHistoryID(id) else { throw OperationHistoryStoreError.invalidID }
        let cutoff = Self.historyTimestamp(now()).addingTimeInterval(-Self.retentionInterval)
        switch try withLockedRoot(createIfMissing: false, { rootFD in
            var state: FoldState?
            try forEachDateFile(rootFD: rootFD) { fileName in
                try forEachStoredLine(fileName, rootFD: rootFD) { line in
                    guard line.event.id == id else { return }
                    try Self.applyTargetEvent(line.event, fileName: fileName, to: &state)
                }
            }
            guard let state, state.startedAt >= cutoff else {
                return Optional<OperationHistoryRecord>.none
            }
            return Optional(Self.record(id: id, state: state))
        }) {
        case .missing:
            return nil
        case let .value(record):
            return record
        }
    }

    private func pruneWholeExpiredDateFiles(rootFD: Int32, reference: Date) throws {
        try cleanupStaleTemporaryFiles(rootFD: rootFD)
        let cutoff = reference.addingTimeInterval(-Self.retentionInterval)
        try forEachDateFile(rootFD: rootFD) { fileName in
            if try Self.dateFileRetention(fileName, cutoff: cutoff) == .expired {
                try removeControlledFile(fileName, rootFD: rootFD)
            }
        }
    }

    private func prune(rootFD: Int32, reference: Date) throws {
        try cleanupStaleTemporaryFiles(rootFD: rootFD)
        let cutoff = reference.addingTimeInterval(-Self.retentionInterval)
        try forEachDateFile(rootFD: rootFD) { fileName in
            switch try Self.dateFileRetention(fileName, cutoff: cutoff) {
            case .expired:
                try removeControlledFile(fileName, rootFD: rootFD)
            case .boundary:
                try pruneDateFile(fileName, cutoff: cutoff, rootFD: rootFD)
            case .retained:
                break
            }
        }
    }

    private func pruneDateFile(_ fileName: String, cutoff: Date, rootFD: Int32) throws {
        var states: [String: PruneState] = [:]
        var hasExpired = false
        try forEachStoredLine(fileName, rootFD: rootFD, reportMigrationWarnings: false) { line in
            let event = line.event
            switch event.kind {
            case .started:
                guard states[event.id] == nil, let startedAt = event.startedAt else {
                    throw OperationHistoryStoreError.unavailable
                }
                let keep = startedAt >= cutoff
                states[event.id] = PruneState(keep: keep, completed: false)
                hasExpired = hasExpired || keep == false
            case .completed:
                guard var state = states[event.id], state.completed == false else {
                    throw OperationHistoryStoreError.unavailable
                }
                state.completed = true
                states[event.id] = state
            }
        }
        guard states.isEmpty == false else {
            try removeControlledFileIfPresent(fileName, rootFD: rootFD)
            return
        }
        guard hasExpired else { return }
        guard states.values.contains(where: \.keep) else {
            try removeControlledFile(fileName, rootFD: rootFD)
            return
        }
        try replaceControlledFile(fileName, rootFD: rootFD) { temporaryFD in
            try forEachStoredLine(fileName, rootFD: rootFD, reportMigrationWarnings: false) { line in
                guard states[line.event.id]?.keep == true else { return }
                var data = try Self.encoder().encode(line.event.v2Event)
                guard data.count <= Self.eventByteCap else { throw OperationHistoryStoreError.unavailable }
                data.append(0x0A)
                try Self.writeAll(data, to: temporaryFD)
            }
        }
    }

    private func targetRecord(id: String, fileName: String, rootFD: Int32) throws -> OperationHistoryRecord? {
        var state: FoldState?
        try forEachStoredLine(fileName, rootFD: rootFD) { line in
            guard line.event.id == id else { return }
            try Self.applyTargetEvent(line.event, fileName: fileName, to: &state)
        }
        return state.map { Self.record(id: id, state: $0) }
    }

    private static func boundedCompletionEvent(
        id: String,
        completedAt: Date,
        exitCode: Int32,
        completion: OperationHistoryCompletion?
    ) throws -> OperationHistoryEvent {
        let result = completion?.result ?? .unavailable
        let inverse = completion?.inverse ?? .unavailable
        let candidates = [
            OperationHistoryEvent.completed(
                id: id,
                completedAt: completedAt,
                exitCode: exitCode,
                result: result,
                inverse: inverse
            ),
            OperationHistoryEvent.completed(
                id: id,
                completedAt: completedAt,
                exitCode: exitCode,
                result: result,
                inverse: .unavailable
            ),
            OperationHistoryEvent.completed(
                id: id,
                completedAt: completedAt,
                exitCode: exitCode,
                result: result.withoutWarnings,
                inverse: .unavailable
            ),
        ]
        for event in candidates where try encoder().encode(event).count <= eventByteCap {
            return event
        }
        throw OperationHistoryStoreError.unavailable
    }

    private func append(_ event: OperationHistoryEvent, to fileName: String, rootFD: Int32) throws {
        guard Self.isDateFileName(fileName) else { throw OperationHistoryStoreError.unavailable }
        let fd = openat(
            rootFD,
            fileName,
            O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(fd) }
        try secureRegularFile(fd)
        try Self.repairTrailingPartialLine(fd)

        var data = try Self.encoder().encode(event)
        guard data.count <= Self.eventByteCap else { throw OperationHistoryStoreError.unavailable }
        data.append(0x0A)
        try Self.writeAll(data, to: fd)
        guard fsync(fd) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func forEachStoredLine(
        _ fileName: String,
        rootFD: Int32,
        reportMigrationWarnings: Bool = true,
        _ body: (StoredLine) throws -> Void
    ) throws {
        guard Self.isDateFileName(fileName) else { throw OperationHistoryStoreError.unavailable }
        let fd = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(fd) }
        try secureRegularFile(fd)
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw OperationHistoryStoreError.unavailable }

        var buffer = [UInt8](repeating: 0, count: Self.lineReadChunkSize)
        var line = [UInt8]()
        line.reserveCapacity(Self.lineReadChunkSize)
        var bufferingLine = true
        var legacyTokenizer = LegacyHistoryScalarTokenizer()
        var absoluteOffset: off_t = 0
        var lastCompleteOffset: off_t = 0

        func finishLine() throws {
            let event: OperationHistoryEvent?
            if bufferingLine {
                do {
                    let decoded = try Self.decoder().decode(OperationHistoryEvent.self, from: Data(line))
                    try decoded.validate()
                    event = decoded
                } catch {
                    switch legacyTokenizer.finish() {
                    case let .event(legacy): event = legacy
                    case .malformedLegacy:
                        if reportMigrationWarnings { observeMigrationWarning() }
                        event = nil
                    case .notLegacy:
                        throw OperationHistoryStoreError.unavailable
                    }
                }
            } else {
                switch legacyTokenizer.finish() {
                case let .event(legacy): event = legacy
                case .malformedLegacy:
                    if reportMigrationWarnings { observeMigrationWarning() }
                    event = nil
                case .notLegacy:
                    throw OperationHistoryStoreError.unavailable
                }
            }
            if let event {
                try body(StoredLine(fileName: fileName, event: event))
            }
            line.removeAll(keepingCapacity: true)
            bufferingLine = true
            legacyTokenizer = LegacyHistoryScalarTokenizer()
        }

        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                for byte in buffer.prefix(count) {
                    absoluteOffset += 1
                    if byte == 0x0A {
                        guard bufferingLine == false || line.isEmpty == false else {
                            throw OperationHistoryStoreError.unavailable
                        }
                        try finishLine()
                        lastCompleteOffset = absoluteOffset
                        continue
                    }

                    legacyTokenizer.consume(byte)
                    if bufferingLine {
                        if line.count < Self.legacyBufferedLineByteCap {
                            line.append(byte)
                            observeLineBufferedBytes(line.count)
                        } else {
                            bufferingLine = false
                            line.removeAll(keepingCapacity: false)
                        }
                    }
                }
            } else if count == 0 {
                if bufferingLine == false || line.isEmpty == false {
                    guard ftruncate(fd, lastCompleteOffset) == 0,
                          fsync(fd) == 0 else {
                        throw OperationHistoryStoreError.unavailable
                    }
                }
                return
            } else if errno != EINTR {
                throw OperationHistoryStoreError.unavailable
            }
        }
    }

    private func cleanupStaleTemporaryFiles(rootFD: Int32) throws {
        try forEachDirectoryName(rootFD: rootFD) { name in
            guard Self.isTemporaryFileName(name) else { return }
            let fd = openat(rootFD, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
            do {
                try secureRegularFile(fd)
            } catch {
                Darwin.close(fd)
                throw error
            }
            Darwin.close(fd)
            guard unlinkat(rootFD, name, 0) == 0 else { throw OperationHistoryStoreError.unavailable }
        }
    }

    private func removeControlledFileIfPresent(_ fileName: String, rootFD: Int32) throws {
        let fd = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return }
            throw OperationHistoryStoreError.unavailable
        }
        do {
            try secureRegularFile(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        Darwin.close(fd)
        guard unlinkat(rootFD, fileName, 0) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func removeControlledFile(_ fileName: String, rootFD: Int32) throws {
        let fd = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureRegularFile(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
        Darwin.close(fd)
        guard unlinkat(rootFD, fileName, 0) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func replaceControlledFile(
        _ fileName: String,
        rootFD: Int32,
        writeBody: (Int32) throws -> Void
    ) throws {
        let temporaryName = Self.temporaryFileName()
        let temporaryFD = openat(
            rootFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            Self.fileMode
        )
        guard temporaryFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        var temporaryExists = true
        defer {
            Darwin.close(temporaryFD)
            if temporaryExists { _ = unlinkat(rootFD, temporaryName, 0) }
        }
        try secureRegularFile(temporaryFD)
        try writeBody(temporaryFD)
        guard fsync(temporaryFD) == 0 else { throw OperationHistoryStoreError.unavailable }

        let destinationFD = openat(rootFD, fileName, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard destinationFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureRegularFile(destinationFD)
        } catch {
            Darwin.close(destinationFD)
            throw error
        }
        Darwin.close(destinationFD)

        guard renameat(rootFD, temporaryName, rootFD, fileName) == 0,
              fsync(rootFD) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
        temporaryExists = false
    }

    private func forEachDateFile(rootFD: Int32, _ body: (String) throws -> Void) throws {
        try forEachDirectoryName(rootFD: rootFD) { name in
            guard Self.isDateFileName(name) else { return }
            try body(name)
        }
    }

    private func forEachDirectoryName(rootFD: Int32, _ body: (String) throws -> Void) throws {
        let directoryFD = openat(rootFD, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        guard let directory = fdopendir(directoryFD) else {
            Darwin.close(directoryFD)
            throw OperationHistoryStoreError.unavailable
        }
        defer { closedir(directory) }

        while true {
            errno = 0
            guard let pointer = readdir(directory) else {
                guard errno == 0 else { throw OperationHistoryStoreError.unavailable }
                return
            }
            var entry = pointer.pointee
            let name = withUnsafePointer(to: &entry.d_name) { value in
                value.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            try body(name)
        }
    }

    private func historyGeneration(rootFD: Int32) throws -> CursorGeneration {
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw CursorPaginationError.generationUnavailable
        }
        var accumulator = [UInt8](repeating: 0, count: 32)
        var count: UInt64 = 0
        try forEachDateFile(rootFD: rootFD) { fileName in
            let fd = openat(rootFD, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CursorPaginationError.generationUnavailable }
            defer { Darwin.close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == geteuid(),
                  info.st_size >= 0 else {
                throw CursorPaginationError.generationUnavailable
            }
            var entry = Data("applebookscli.history.generation.entry.v1".utf8)
            Self.appendLengthPrefixed(Data(fileName.utf8), to: &entry)
            Self.appendFileStat(info, to: &entry)
            Self.addDigestModulo256(Array(SHA256.hash(data: entry)), into: &accumulator)
            guard count < UInt64.max else { throw CursorPaginationError.internalContractFailure }
            count += 1
        }
        var digestInput = Data("applebookscli.history.generation.v1".utf8)
        Self.appendUInt64(UInt64(bitPattern: Int64(rootInfo.st_dev)), to: &digestInput)
        Self.appendUInt64(UInt64(rootInfo.st_ino), to: &digestInput)
        Self.appendUInt64(count, to: &digestInput)
        digestInput.append(contentsOf: accumulator)
        let digest = SHA256.hash(data: digestInput).map { String(format: "%02x", $0) }.joined()
        return try CursorGeneration.compose([
            CursorGenerationComponent.synthetic(label: "history-store", value: digest),
        ])
    }

    private func withLockedRoot<Value>(
        createIfMissing: Bool,
        _ body: (Int32) throws -> Value
    ) throws -> LockedRootResult<Value> {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        guard let rootFD = try openRoot(createIfMissing: createIfMissing) else { return .missing }
        defer { Darwin.close(rootFD) }

        let lockFD = openat(
            rootFD,
            Self.lockFileName,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK,
            Self.fileMode
        )
        guard lockFD >= 0 else { throw OperationHistoryStoreError.unavailable }
        defer { Darwin.close(lockFD) }
        try secureRegularFile(lockFD)
        let value = try body(rootFD)
        try validateRootIdentity(rootFD)
        return .value(value)
    }

    private func openRoot(createIfMissing: Bool) throws -> Int32? {
        var rootStat = stat()
        if lstat(root.path, &rootStat) != 0 {
            guard errno == ENOENT else { throw OperationHistoryStoreError.unavailable }
            guard createIfMissing else { return nil }
            let parent = root.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw OperationHistoryStoreError.unavailable
            }
            guard parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else {
                throw OperationHistoryStoreError.unavailable
            }
            if mkdir(root.path, Self.directoryMode) != 0, errno != EEXIST {
                throw OperationHistoryStoreError.unavailable
            }
        }

        guard root.resolvingSymlinksInPath().path == root.path else {
            throw OperationHistoryStoreError.unavailable
        }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw OperationHistoryStoreError.unavailable }
        do {
            try secureDirectory(fd)
            try validateRootIdentity(fd)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func validateRootIdentity(_ fd: Int32) throws {
        var opened = stat()
        var current = stat()
        guard fstat(fd, &opened) == 0,
              lstat(root.path, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              current.st_uid == geteuid(),
              opened.st_dev == current.st_dev,
              opened.st_ino == current.st_ino else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private func secureDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid() else {
            throw OperationHistoryStoreError.unavailable
        }
        if info.st_mode & mode_t(0o777) != Self.directoryMode {
            guard fchmod(fd, Self.directoryMode) == 0 else { throw OperationHistoryStoreError.unavailable }
        }
    }

    private func secureRegularFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid() else {
            throw OperationHistoryStoreError.unavailable
        }
        if info.st_mode & mode_t(0o777) != Self.fileMode {
            guard fchmod(fd, Self.fileMode) == 0 else { throw OperationHistoryStoreError.unavailable }
        }
    }

    private static func applyTargetEvent(
        _ event: OperationHistoryEvent,
        fileName: String,
        to state: inout FoldState?
    ) throws {
        switch event.kind {
        case .started:
            guard state == nil,
                  let operation = event.operation,
                  let request = event.semanticRequest,
                  let startedAt = event.startedAt else {
                throw OperationHistoryStoreError.unavailable
            }
            state = FoldState(
                operation: operation,
                request: request,
                startedAt: startedAt,
                fileName: fileName,
                completed: nil
            )
        case .completed:
            guard var current = state,
                  current.fileName == fileName,
                  current.completed == nil,
                  let completedAt = event.completedAt,
                  let exitCode = event.exitCode,
                  let result = event.semanticResult,
                  let inverse = event.semanticInverse else {
                throw OperationHistoryStoreError.unavailable
            }
            current.completed = CompletedState(
                completedAt: completedAt,
                exitCode: exitCode,
                result: result,
                inverse: inverse
            )
            state = current
        }
    }

    private static func record(id: String, state: FoldState) -> OperationHistoryRecord {
        let completed = state.completed
        return OperationHistoryRecord(
            id: id,
            operation: state.operation,
            request: state.request,
            startedAt: state.startedAt,
            completedAt: completed?.completedAt,
            exitCode: completed?.exitCode,
            result: completed?.result,
            inverse: completed?.inverse ?? .unavailable,
            status: completed.map { $0.exitCode == 0 ? .success : .failure } ?? .incomplete,
            fileName: state.fileName
        )
    }

    private static func retainHistoryCandidate(
        _ candidate: HistoryListCandidate,
        maximumCount: Int,
        in candidates: inout [HistoryListCandidate]
    ) throws {
        guard maximumCount > 0 else { throw CursorPaginationError.internalContractFailure }
        if candidates.contains(where: { $0.id == candidate.id }) {
            throw OperationHistoryStoreError.unavailable
        }
        if candidates.count < maximumCount {
            candidates.append(candidate)
            candidates.sort(by: historyCandidateOrder)
            return
        }
        guard let last = candidates.last, historyCandidateOrder(candidate, last) else { return }
        candidates.append(candidate)
        candidates.sort(by: historyCandidateOrder)
        candidates.removeLast()
    }

    private static func historyCandidateOrder(_ lhs: HistoryListCandidate, _ rhs: HistoryListCandidate) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id < rhs.id
    }

    private static func isAfter(_ key: HistoryAnchor, anchor: HistoryAnchor?) -> Bool {
        guard let anchor else { return true }
        if key.startedAt != anchor.startedAt { return key.startedAt < anchor.startedAt }
        return key.id > anchor.id
    }

    private static func historyLocator(_ record: OperationHistorySummaryRecord) throws -> CursorLocator {
        let seconds = record.startedAt.timeIntervalSince1970
        guard seconds.isFinite,
              seconds.rounded(.towardZero) == seconds,
              seconds >= Double(Int64.min),
              seconds <= Double(Int64.max),
              let uuid = UUID(uuidString: record.id),
              record.id == uuid.uuidString.lowercased() else {
            throw CursorPaginationError.internalContractFailure
        }
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        guard bytes.count == 16 else { throw CursorPaginationError.internalContractFailure }
        return try CursorLocator(words: [
            UInt64(bitPattern: Int64(seconds)),
            packHistoryBytes(bytes[0..<8]),
            packHistoryBytes(bytes[8..<16]),
        ])
    }

    private static func historyAnchor(from locator: CursorLocator?) throws -> HistoryAnchor? {
        guard let locator else { return nil }
        guard locator.words.count == 3 else { throw CursorPaginationError.invalidCursor }
        let seconds = Int64(bitPattern: locator.words[0])
        let bytes = unpackHistoryWord(locator.words[1]) + unpackHistoryWord(locator.words[2])
        guard bytes.count == 16 else { throw CursorPaginationError.invalidCursor }
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        let id = UUID(uuid: tuple).uuidString.lowercased()
        return HistoryAnchor(startedAt: Date(timeIntervalSince1970: TimeInterval(seconds)), id: id)
    }

    private static func packHistoryBytes(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func unpackHistoryWord(_ value: UInt64) -> [UInt8] {
        stride(from: 56, through: 0, by: -8).map { shift in
            UInt8((value >> UInt64(shift)) & 0xff)
        }
    }

    private static func isCanonicalHistoryID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              value.unicodeScalars.allSatisfy({ $0.isASCII }),
              let uuid = UUID(uuidString: value) else {
            return false
        }
        return value == uuid.uuidString.lowercased()
    }

    private static func appendFileStat(_ info: stat, to data: inout Data) {
        appendUInt64(UInt64(bitPattern: Int64(info.st_dev)), to: &data)
        appendUInt64(UInt64(info.st_ino), to: &data)
        appendUInt64(UInt64(info.st_size), to: &data)
        appendUInt64(UInt64(bitPattern: Int64(info.st_mtimespec.tv_sec)), to: &data)
        appendUInt64(UInt64(bitPattern: Int64(info.st_mtimespec.tv_nsec)), to: &data)
    }

    private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
        appendUInt64(UInt64(value.count), to: &data)
        data.append(value)
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func addDigestModulo256(_ value: [UInt8], into accumulator: inout [UInt8]) {
        precondition(value.count == accumulator.count)
        var carry: UInt16 = 0
        for index in stride(from: accumulator.count - 1, through: 0, by: -1) {
            let sum = UInt16(accumulator[index]) + UInt16(value[index]) + carry
            accumulator[index] = UInt8(sum & 0xff)
            carry = sum >> 8
        }
    }

    private static func repairTrailingPartialLine(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 0 else {
            throw OperationHistoryStoreError.unavailable
        }
        let size = info.st_size
        guard size > 0 else { return }

        var lastByte: UInt8 = 0
        let lastRead = withUnsafeMutableBytes(of: &lastByte) { bytes in
            Darwin.pread(fd, bytes.baseAddress, 1, size - 1)
        }
        guard lastRead == 1 else { throw OperationHistoryStoreError.unavailable }
        guard lastByte != 0x0A else { return }

        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw OperationHistoryStoreError.unavailable }
        var buffer = [UInt8](repeating: 0, count: Self.lineReadChunkSize)
        var absoluteOffset: off_t = 0
        var lastCompleteOffset: off_t = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                for byte in buffer.prefix(count) {
                    absoluteOffset += 1
                    if byte == 0x0A { lastCompleteOffset = absoluteOffset }
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw OperationHistoryStoreError.unavailable
            }
        }

        guard ftruncate(fd, lastCompleteOffset) == 0,
              fsync(fd) == 0 else {
            throw OperationHistoryStoreError.unavailable
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw OperationHistoryStoreError.unavailable
                }
            }
        }
    }

    private static func historyTimestamp(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }

    private static func dateFileName(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d.jsonl",
            locale: Locale(identifier: "en_US_POSIX"),
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func isDateFileName(_ name: String) -> Bool {
        dateFileDayUTC(name) != nil
    }

    private static func dateFileRetention(_ name: String, cutoff: Date) throws -> DateFileRetention {
        guard let day = dateFileDayUTC(name) else { throw OperationHistoryStoreError.unavailable }
        // ponytail: partitions use the caller's local timezone. A timezone offset is always within one civil day,
        // so this two-day UTC envelope is conservative across travel/DST without remembering historical zones.
        let earliestPossibleStart = day.addingTimeInterval(-24 * 60 * 60)
        let latestPossibleStartExclusive = day.addingTimeInterval(2 * 24 * 60 * 60)
        if latestPossibleStartExclusive <= cutoff { return .expired }
        if earliestPossibleStart >= cutoff { return .retained }
        return .boundary
    }

    private static func dateFileDayUTC(_ name: String) -> Date? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let date = String(name.dropLast(".jsonl".count))
        let parts = date.split(separator: "-", omittingEmptySubsequences: false)
        guard date.utf8.count == 10,
              parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              (1...9999).contains(year) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let value = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day], from: value)
        guard checked.year == year, checked.month == month, checked.day == day else { return nil }
        return value
    }

    private static func temporaryFileName() -> String {
        temporaryPrefix + UUID().uuidString.lowercased() + temporarySuffix
    }

    private static func isTemporaryFileName(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryPrefix), name.hasSuffix(temporarySuffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: temporaryPrefix.count)
        let end = name.index(name.endIndex, offsetBy: -temporarySuffix.count)
        let rawID = String(name[start..<end])
        guard let uuid = UUID(uuidString: rawID) else { return false }
        return rawID == uuid.uuidString.lowercased()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct OperationHistoryEvent: Codable {
    enum Kind: String, Codable {
        case started
        case completed
    }

    let schemaVersion: Int
    let kind: Kind
    let id: String
    let operation: String?
    let request: OperationHistoryRequest?
    let startedAt: Date?
    let completedAt: Date?
    let exitCode: Int32?
    let result: OperationHistoryResult?
    let inverse: OperationHistoryInverse?

    // v1 read-only compatibility. New writes never populate these fields.
    let arguments: [String]?
    let stdout: String?
    let stderr: String?

    static func started(id: String, operation: String, request: OperationHistoryRequest, startedAt: Date) -> Self {
        Self(
            schemaVersion: OperationHistoryStore.schemaVersion,
            kind: .started,
            id: id,
            operation: operation,
            request: request,
            startedAt: startedAt,
            completedAt: nil,
            exitCode: nil,
            result: nil,
            inverse: nil,
            arguments: nil,
            stdout: nil,
            stderr: nil
        )
    }

    static func completed(
        id: String,
        completedAt: Date,
        exitCode: Int32,
        result: OperationHistoryResult,
        inverse: OperationHistoryInverse
    ) -> Self {
        Self(
            schemaVersion: OperationHistoryStore.schemaVersion,
            kind: .completed,
            id: id,
            operation: nil,
            request: nil,
            startedAt: nil,
            completedAt: completedAt,
            exitCode: exitCode,
            result: result,
            inverse: inverse,
            arguments: nil,
            stdout: nil,
            stderr: nil
        )
    }

    func validate() throws {
        guard (schemaVersion == 1 || schemaVersion == OperationHistoryStore.schemaVersion),
              let uuid = UUID(uuidString: id),
              id == uuid.uuidString.lowercased() else {
            throw OperationHistoryStoreError.unavailable
        }
        switch (schemaVersion, kind) {
        case (1, .started):
            guard let operation, operation.isEmpty == false,
                  arguments != nil,
                  startedAt != nil,
                  completedAt == nil,
                  exitCode == nil else {
                throw OperationHistoryStoreError.unavailable
            }
        case (1, .completed):
            guard operation == nil,
                  startedAt == nil,
                  completedAt != nil,
                  exitCode != nil else {
                throw OperationHistoryStoreError.unavailable
            }
        case (OperationHistoryStore.schemaVersion, .started):
            guard let operation, operation.isEmpty == false,
                  request != nil,
                  startedAt != nil,
                  completedAt == nil,
                  exitCode == nil,
                  result == nil,
                  inverse == nil,
                  arguments == nil,
                  stdout == nil,
                  stderr == nil else {
                throw OperationHistoryStoreError.unavailable
            }
        case (OperationHistoryStore.schemaVersion, .completed):
            guard operation == nil,
                  request == nil,
                  startedAt == nil,
                  completedAt != nil,
                  exitCode != nil,
                  result != nil,
                  inverse != nil,
                  arguments == nil,
                  stdout == nil,
                  stderr == nil else {
                throw OperationHistoryStoreError.unavailable
            }
        default:
            throw OperationHistoryStoreError.unavailable
        }
    }

    var semanticRequest: OperationHistoryRequest? {
        schemaVersion == 1 ? .unavailable : request
    }

    var semanticResult: OperationHistoryResult? {
        schemaVersion == 1 ? .unavailable : result
    }

    var semanticInverse: OperationHistoryInverse? {
        schemaVersion == 1 ? .unavailable : inverse
    }

    var v2Event: Self {
        guard schemaVersion == 1 else { return self }
        switch kind {
        case .started:
            return .started(
                id: id,
                operation: operation ?? "unknown",
                request: .unavailable,
                startedAt: startedAt ?? Date(timeIntervalSince1970: 0)
            )
        case .completed:
            return .completed(
                id: id,
                completedAt: completedAt ?? Date(timeIntervalSince1970: 0),
                exitCode: exitCode ?? CLIProcessExit.internal.rawValue,
                result: .unavailable,
                inverse: .unavailable
            )
        }
    }
}

private struct LegacyHistoryScalarTokenizer {
    enum FinishResult {
        case event(OperationHistoryEvent)
        case malformedLegacy
        case notLegacy
    }

    private enum State {
        case start
        case keyOrEnd
        case keyString
        case colon
        case value
        case stringValue
        case primitiveValue
        case compositeValue
        case commaOrEnd
        case done
        case invalid
    }

    private static let legacyMarker = Array(#"\"schemaVersion\":1"#.utf8)
    private static let knownKeys: Set<String> = [
        "schemaVersion", "kind", "id", "operation", "arguments", "startedAt",
        "completedAt", "exitCode", "stdout", "stderr",
    ]
    private static let capturedStringByteCap = 4 * 1_024

    private var state: State = .start
    private var keyBytes: [UInt8] = []
    private var valueBytes: [UInt8] = []
    private var currentKey: String?
    private var stringEscaped = false
    private var compositeStack: [UInt8] = []
    private var compositeInString = false
    private var compositeEscaped = false
    private var seenKnownKeys = Set<String>()
    private var markerIndex = 0
    private var sawLegacyMarker = false

    private var schemaVersion: Int?
    private var kind: String?
    private var id: String?
    private var operation: String?
    private var startedAt: String?
    private var completedAt: String?
    private var exitCode: Int32?
    private var sawArguments = false
    private var sawStdout = false
    private var sawStderr = false

    mutating func consume(_ byte: UInt8) {
        observeLegacyMarker(byte)
        guard state != .invalid else { return }

        switch state {
        case .start:
            if Self.isWhitespace(byte) { return }
            state = byte == 0x7B ? .keyOrEnd : .invalid

        case .keyOrEnd:
            if Self.isWhitespace(byte) { return }
            if byte == 0x7D {
                state = .done
            } else if byte == 0x22 {
                keyBytes.removeAll(keepingCapacity: true)
                state = .keyString
            } else {
                state = .invalid
            }

        case .keyString:
            if byte == 0x22 {
                guard let key = String(bytes: keyBytes, encoding: .utf8), key.isEmpty == false else {
                    state = .invalid
                    return
                }
                currentKey = key
                if Self.knownKeys.contains(key) {
                    guard seenKnownKeys.insert(key).inserted else {
                        state = .invalid
                        return
                    }
                    switch key {
                    case "arguments": sawArguments = true
                    case "stdout": sawStdout = true
                    case "stderr": sawStderr = true
                    default: break
                    }
                }
                state = .colon
            } else if byte == 0x5C || byte < 0x20 || keyBytes.count >= 64 {
                state = .invalid
            } else {
                keyBytes.append(byte)
            }

        case .colon:
            if Self.isWhitespace(byte) { return }
            state = byte == 0x3A ? .value : .invalid

        case .value:
            if Self.isWhitespace(byte) { return }
            if byte == 0x22 {
                valueBytes.removeAll(keepingCapacity: true)
                if capturesCurrentValue { valueBytes.append(byte) }
                stringEscaped = false
                state = .stringValue
            } else if byte == 0x5B || byte == 0x7B {
                guard capturesCurrentValue == false else {
                    state = .invalid
                    return
                }
                compositeStack = [byte]
                compositeInString = false
                compositeEscaped = false
                state = .compositeValue
            } else if Self.isPrimitiveStart(byte) {
                valueBytes.removeAll(keepingCapacity: true)
                if capturesCurrentValue { valueBytes.append(byte) }
                state = .primitiveValue
            } else {
                state = .invalid
            }

        case .stringValue:
            if capturesCurrentValue {
                guard valueBytes.count < Self.capturedStringByteCap else {
                    state = .invalid
                    return
                }
                valueBytes.append(byte)
            }
            if stringEscaped {
                stringEscaped = false
            } else if byte == 0x5C {
                stringEscaped = true
            } else if byte == 0x22 {
                finalizeStringValue()
                if state != .invalid { state = .commaOrEnd }
            } else if byte < 0x20 {
                state = .invalid
            }

        case .primitiveValue:
            if Self.isWhitespace(byte) {
                finalizePrimitiveValue()
                if state != .invalid { state = .commaOrEnd }
            } else if byte == 0x2C {
                finalizePrimitiveValue()
                if state != .invalid { state = .keyOrEnd }
            } else if byte == 0x7D {
                finalizePrimitiveValue()
                if state != .invalid { state = .done }
            } else if Self.isPrimitiveBody(byte) {
                if capturesCurrentValue {
                    guard valueBytes.count < 64 else {
                        state = .invalid
                        return
                    }
                    valueBytes.append(byte)
                }
            } else {
                state = .invalid
            }

        case .compositeValue:
            consumeComposite(byte)

        case .commaOrEnd:
            if Self.isWhitespace(byte) { return }
            if byte == 0x2C {
                currentKey = nil
                state = .keyOrEnd
            } else if byte == 0x7D {
                currentKey = nil
                state = .done
            } else {
                state = .invalid
            }

        case .done:
            if Self.isWhitespace(byte) == false { state = .invalid }

        case .invalid:
            break
        }
    }

    func finish() -> FinishResult {
        guard state == .done,
              schemaVersion == 1,
              let kind,
              let id,
              let uuid = UUID(uuidString: id),
              id == uuid.uuidString.lowercased() else {
            return (schemaVersion == 1 || sawLegacyMarker) ? .malformedLegacy : .notLegacy
        }

        let event: OperationHistoryEvent
        switch kind {
        case OperationHistoryEvent.Kind.started.rawValue:
            guard let operation, operation.isEmpty == false,
                  let startedAt = Self.date(startedAt),
                  sawArguments,
                  completedAt == nil,
                  exitCode == nil,
                  sawStdout == false,
                  sawStderr == false else {
                return .malformedLegacy
            }
            event = OperationHistoryEvent(
                schemaVersion: 1,
                kind: .started,
                id: id,
                operation: operation,
                request: nil,
                startedAt: startedAt,
                completedAt: nil,
                exitCode: nil,
                result: nil,
                inverse: nil,
                arguments: [],
                stdout: nil,
                stderr: nil
            )
        case OperationHistoryEvent.Kind.completed.rawValue:
            guard operation == nil,
                  startedAt == nil,
                  let completedAt = Self.date(completedAt),
                  let exitCode,
                  sawArguments == false,
                  sawStdout,
                  sawStderr else {
                return .malformedLegacy
            }
            event = OperationHistoryEvent(
                schemaVersion: 1,
                kind: .completed,
                id: id,
                operation: nil,
                request: nil,
                startedAt: nil,
                completedAt: completedAt,
                exitCode: exitCode,
                result: nil,
                inverse: nil,
                arguments: nil,
                stdout: "",
                stderr: ""
            )
        default:
            return .malformedLegacy
        }

        do {
            try event.validate()
            return .event(event)
        } catch {
            return .malformedLegacy
        }
    }

    private var capturesCurrentValue: Bool {
        switch currentKey {
        case "schemaVersion", "kind", "id", "operation", "startedAt", "completedAt", "exitCode": true
        default: false
        }
    }

    private mutating func finalizeStringValue() {
        defer {
            valueBytes.removeAll(keepingCapacity: true)
            currentKey = nil
        }
        guard capturesCurrentValue,
              let key = currentKey,
              let value = try? JSONDecoder().decode(String.self, from: Data(valueBytes)) else {
            if capturesCurrentValue { state = .invalid }
            return
        }
        switch key {
        case "kind": kind = value
        case "id": id = value
        case "operation": operation = value
        case "startedAt": startedAt = value
        case "completedAt": completedAt = value
        default: state = .invalid
        }
    }

    private mutating func finalizePrimitiveValue() {
        defer {
            valueBytes.removeAll(keepingCapacity: true)
            currentKey = nil
        }
        guard capturesCurrentValue, let key = currentKey else { return }
        guard let raw = String(bytes: valueBytes, encoding: .utf8) else {
            state = .invalid
            return
        }
        switch key {
        case "schemaVersion":
            schemaVersion = Int(raw)
            if schemaVersion == nil { state = .invalid }
        case "exitCode":
            exitCode = Int32(raw)
            if exitCode == nil { state = .invalid }
        case "operation" where raw == "null",
             "startedAt" where raw == "null",
             "completedAt" where raw == "null":
            break
        default:
            state = .invalid
        }
    }

    private mutating func consumeComposite(_ byte: UInt8) {
        if compositeInString {
            if compositeEscaped {
                compositeEscaped = false
            } else if byte == 0x5C {
                compositeEscaped = true
            } else if byte == 0x22 {
                compositeInString = false
            } else if byte < 0x20 {
                state = .invalid
            }
            return
        }

        if byte == 0x22 {
            compositeInString = true
            return
        }
        if byte == 0x5B || byte == 0x7B {
            guard compositeStack.count < 64 else {
                state = .invalid
                return
            }
            compositeStack.append(byte)
            return
        }
        if byte == 0x5D || byte == 0x7D {
            guard let opening = compositeStack.last,
                  (opening == 0x5B && byte == 0x5D) || (opening == 0x7B && byte == 0x7D) else {
                state = .invalid
                return
            }
            compositeStack.removeLast()
            if compositeStack.isEmpty {
                currentKey = nil
                state = .commaOrEnd
            }
        }
    }

    private mutating func observeLegacyMarker(_ byte: UInt8) {
        guard sawLegacyMarker == false else { return }
        let marker = Self.legacyMarker
        if byte == marker[markerIndex] {
            markerIndex += 1
            if markerIndex == marker.count {
                sawLegacyMarker = true
                markerIndex = 0
            }
        } else {
            markerIndex = byte == marker[0] ? 1 : 0
        }
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D
    }

    private static func isPrimitiveStart(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x6E || byte == 0x74 || byte == 0x66
    }

    private static func isPrimitiveBody(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || byte == 0x2D || byte == 0x2B || byte == 0x2E
            || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}

private struct StoredLine {
    let fileName: String
    let event: OperationHistoryEvent
}

private struct HistoryAnchor: Equatable {
    let startedAt: Date
    let id: String
}

private struct HistoryListCandidate {
    let id: String
    let operation: String
    let startedAt: Date
    var completedAt: Date?
    var exitCode: Int32?

    var summary: OperationHistorySummaryRecord {
        OperationHistorySummaryRecord(
            id: id,
            operation: operation,
            startedAt: startedAt,
            completedAt: completedAt,
            exitCode: exitCode,
            status: exitCode.map { $0 == 0 ? .success : .failure } ?? .incomplete
        )
    }
}

private enum DateFileRetention {
    case expired
    case boundary
    case retained
}

private struct PruneState {
    let keep: Bool
    var completed: Bool
}

private struct CompletedState {
    let completedAt: Date
    let exitCode: Int32
    let result: OperationHistoryResult
    let inverse: OperationHistoryInverse
}

private struct FoldState {
    let operation: String
    let request: OperationHistoryRequest
    let startedAt: Date
    let fileName: String
    var completed: CompletedState?
}

private enum LockedRootResult<Value> {
    case missing
    case value(Value)
}

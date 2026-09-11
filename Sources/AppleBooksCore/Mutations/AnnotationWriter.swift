import Foundation
import SQLite3

public enum AnnotationWriteError: Error, Equatable, Sendable {
    case invalidNoteLength
    case annotationMissing
    case annotationRestoreUnavailable
    case annotationDeletedOrUnknown
    case annotationNotWritable
    case writeFailed
}

struct AnnotationWriter {
    private static let entityName = "AEAnnotation"
    private static let updateColumns: Set<String> = [
        "Z_PK",
        "Z_ENT",
        "Z_OPT",
        "ZANNOTATIONDELETED",
        "ZANNOTATIONTYPE",
        "ZANNOTATIONNOTE",
        "ZANNOTATIONMODIFICATIONDATE",
        "ZFUTUREPROOFING6",
    ]
    private static let deleteColumns: Set<String> = [
        "Z_PK",
        "Z_ENT",
        "Z_OPT",
        "ZANNOTATIONDELETED",
        "ZANNOTATIONTYPE",
        "ZANNOTATIONMODIFICATIONDATE",
        "ZFUTUREPROOFING6",
    ]

    private enum Selector {
        case localPK(Int64)
        case uuid(String)
    }

    private enum TargetState: Equatable {
        case active
        case tombstone
    }

    private struct Target {
        let localPK: Int64
        let entityID: Int64
        let stableID: String?
        let appleBooksURL: String?
        let state: TargetState
    }

    private struct NoteMutation {
        let target: Target
        let changed: Bool
        let historyEffect: MutationHistoryEffect?
    }

    private struct StateMutation {
        let target: Target
        let changed: Bool
    }

    private let coordinator: MutationCoordinator
    private let cloudProjector: AnnotationCloudProjector?
    private let cloudSynchronizer: AnnotationCloudSynchronizer?

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksApp: BooksAppController = .live,
        cloudProjector: AnnotationCloudProjector? = nil,
        cloudSynchronizer: AnnotationCloudSynchronizer? = nil
    ) {
        coordinator = MutationCoordinator(
            database: database,
            backupRoot: backupRoot,
            keep: keep,
            booksApp: booksApp
        )
        self.cloudProjector = cloudProjector
        self.cloudSynchronizer = cloudSynchronizer
    }

    func updateNote(
        localPK: Int64,
        note: String?,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try updateNote(.localPK(localPK), note: note, syncCloud: syncCloud)
    }

    func updateNote(
        uuid: String,
        note: String?,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try updateNote(.uuid(uuid), note: note, syncCloud: syncCloud)
    }

    func delete(
        localPK: Int64,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try delete(.localPK(localPK), syncCloud: syncCloud)
    }

    func delete(
        uuid: String,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try delete(.uuid(uuid), syncCloud: syncCloud)
    }

    func restore(
        localPK: Int64,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try restore(.localPK(localPK), syncCloud: syncCloud)
    }

    func restore(
        uuid: String,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try restore(.uuid(uuid), syncCloud: syncCloud)
    }

    private func updateNote(
        _ selector: Selector,
        note: String?,
        syncCloud: Bool
    ) throws -> MutationResult {
        try Self.validateNoteTarget(note)

        return try coordinator.perform(
            preflight: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.validateSchema(for: selector, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            quietDecision: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.validateSchema(for: selector, on: handle)
                let target = try Self.resolve(selector, on: handle)
                guard try Self.currentNote(localPK: target.localPK, on: handle) == note else {
                    return .needsMutation
                }
                return .noChange(Self.domainData(target: target, changed: false))
            },
            revalidate: { handle in
                try Self.validateSchema(for: selector, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            mutation: { handle in
                let target = try Self.resolve(selector, on: handle)
                let previousNote = try Self.currentNote(localPK: target.localPK, on: handle)
                if previousNote == note {
                    return NoteMutation(target: target, changed: false, historyEffect: nil)
                }
                try Self.applyNote(note, to: target.localPK, on: handle)
                return NoteMutation(
                    target: target,
                    changed: true,
                    historyEffect: Self.noteHistoryEffect(previousNote)
                )
            },
            invariant: { handle, payload in
                try Self.verifyNote(
                    note,
                    target: payload.target,
                    requireMutationMetadata: payload.changed,
                    on: handle
                )
            },
            domainData: { payload in
                Self.domainData(target: payload.target, changed: payload.changed)
            },
            historyEffect: { $0.historyEffect },
            cloudProjection: cloudProjector.map { projector in
                { payload in try projector.project(localPK: payload.target.localPK) }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { payload, onTemporaryBooksLaunch in
                    try synchronizer.sync(
                        localPK: payload.target.localPK,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, payload in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.verifyNote(
                    note,
                    target: payload.target,
                    requireMutationMetadata: payload.changed,
                    on: handle
                )
            }
        )
    }

    private func delete(
        _ selector: Selector,
        syncCloud: Bool
    ) throws -> MutationResult {
        try setDeletedState(
            selector,
            targetState: .tombstone,
            missingError: .annotationMissing,
            syncCloud: syncCloud
        )
    }

    private func restore(
        _ selector: Selector,
        syncCloud: Bool
    ) throws -> MutationResult {
        try setDeletedState(
            selector,
            targetState: .active,
            missingError: .annotationRestoreUnavailable,
            syncCloud: syncCloud
        )
    }

    private func setDeletedState(
        _ selector: Selector,
        targetState: TargetState,
        missingError: AnnotationWriteError,
        syncCloud: Bool
    ) throws -> MutationResult {
        try coordinator.perform(
            preflight: { connection in
                guard let handle = connection.handle else { throw missingError }
                try Self.validateSchema(for: selector, required: Self.deleteColumns, on: handle)
                _ = try Self.resolveState(selector, missingError: missingError, on: handle)
            },
            quietDecision: { connection in
                guard let handle = connection.handle else { throw missingError }
                try Self.validateSchema(for: selector, required: Self.deleteColumns, on: handle)
                let target = try Self.resolveState(selector, missingError: missingError, on: handle)
                guard target.state == targetState else { return .needsMutation }
                return .noChange(Self.domainData(target: target, changed: false))
            },
            revalidate: { handle in
                try Self.validateSchema(for: selector, required: Self.deleteColumns, on: handle)
                _ = try Self.resolveState(selector, missingError: missingError, on: handle)
            },
            mutation: { handle in
                let target = try Self.resolveState(selector, missingError: missingError, on: handle)
                guard target.state != targetState else {
                    return StateMutation(target: target, changed: false)
                }
                try Self.applyState(targetState, to: target.localPK, on: handle)
                return StateMutation(target: target, changed: true)
            },
            invariant: { handle, payload in
                try Self.verifyState(
                    targetState,
                    target: payload.target,
                    requireMutationMetadata: payload.changed,
                    on: handle
                )
            },
            domainData: { payload in
                Self.domainData(target: payload.target, changed: payload.changed)
            },
            cloudProjection: cloudProjector.map { projector in
                { payload in try projector.project(localPK: payload.target.localPK) }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { payload, onTemporaryBooksLaunch in
                    try synchronizer.sync(
                        localPK: payload.target.localPK,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, payload in
                guard let handle = connection.handle else { throw missingError }
                try Self.verifyState(
                    targetState,
                    target: payload.target,
                    requireMutationMetadata: payload.changed,
                    on: handle
                )
            }
        )
    }

    static func validateWriteReadiness(on connection: SQLiteConnection) throws {
        guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
        var required = updateColumns
        required.insert("ZANNOTATIONUUID")
        try WriteSchemaGuard.validateTable(.annotations, required: required, inserting: false, on: handle)
        _ = try WriteSchemaGuard.entity(named: entityName, on: handle)
    }

    private static func validateSchema(for selector: Selector, on handle: OpaquePointer) throws {
        try validateSchema(for: selector, required: updateColumns, on: handle)
    }

    private static func validateSchema(
        for selector: Selector,
        required baseRequired: Set<String>,
        on handle: OpaquePointer
    ) throws {
        var required = baseRequired
        if case .uuid = selector {
            required.insert("ZANNOTATIONUUID")
        }
        try WriteSchemaGuard.validateTable(.annotations, required: required, inserting: false, on: handle)
    }

    private static func resolve(_ selector: Selector, on handle: OpaquePointer) throws -> Target {
        let target = try resolveState(selector, missingError: .annotationMissing, on: handle)
        guard target.state == .active else { throw AnnotationWriteError.annotationDeletedOrUnknown }
        return target
    }

    private static func resolveState(
        _ selector: Selector,
        missingError: AnnotationWriteError,
        on handle: OpaquePointer
    ) throws -> Target {
        let entity = try WriteSchemaGuard.entity(named: entityName, on: handle)
        let sql: String
        switch selector {
        case .localPK:
            sql = "SELECT Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONTYPE FROM ZAEANNOTATION WHERE Z_PK=? ORDER BY rowid LIMIT 2"
        case .uuid:
            sql = "SELECT Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONTYPE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2"
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.annotationMissing
        }
        defer { sqlite3_finalize(statement) }

        switch selector {
        case let .localPK(value):
            guard sqlite3_bind_int64(statement, 1, value) == SQLITE_OK else {
                throw AnnotationWriteError.writeFailed
            }
        case let .uuid(value):
            guard bind(value, to: statement, index: 1) == SQLITE_OK else {
                throw AnnotationWriteError.writeFailed
            }
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw missingError
        }
        let row = (
            localPK: sqlite3_column_int64(statement, 0),
            entityID: sqlite3_column_type(statement, 1) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 1) : nil,
            optValid: sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
            deleted: sqlite3_column_type(statement, 3) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 3) : nil,
            type: sqlite3_column_type(statement, 4) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 4) : nil
        )
        let second = sqlite3_step(statement)
        if second == SQLITE_ROW {
            if case .uuid = selector {
                throw StableIdentityError.ambiguousAnnotationUUID
            }
            throw AnnotationWriteError.writeFailed
        }
        guard second == SQLITE_DONE else { throw AnnotationWriteError.writeFailed }
        guard row.entityID == entity.entityID else {
            throw WriteSchemaGuardError.entityMismatch(WriteSchemaTable.annotations.rawValue)
        }
        guard row.optValid else { throw AnnotationWriteError.writeFailed }
        let state: TargetState
        switch row.deleted {
        case 0: state = .active
        case 1: state = .tombstone
        default: throw AnnotationWriteError.annotationDeletedOrUnknown
        }
        guard let type = row.type, type != 3 else { throw AnnotationWriteError.annotationNotWritable }

        let stableID: String?
        if case let .uuid(uuid) = selector {
            stableID = uuid
        } else {
            stableID = annotationUUID(localPK: row.localPK, on: handle)
        }
        return Target(
            localPK: row.localPK,
            entityID: entity.entityID,
            stableID: stableID,
            appleBooksURL: appleBooksURL(localPK: row.localPK, on: handle),
            state: state
        )
    }

    private static func annotationUUID(localPK: Int64, on handle: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT ZANNOTATIONUUID FROM ZAEANNOTATION WHERE Z_PK=? ORDER BY rowid LIMIT 2",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let uuid = try? decodeSQLiteText(statement, at: 0),
              PublicStableIdentityPolicy.isEligible(uuid),
              sqlite3_step(statement) == SQLITE_DONE else {
            return nil
        }
        return uuid
    }

    private static func appleBooksURL(localPK: Int64, on handle: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        let sql = """
        SELECT ZANNOTATIONASSETID,
               CASE
                 WHEN ZANNOTATIONLOCATION IS NOT NULL
                  AND length(CAST(ZANNOTATIONLOCATION AS BLOB)) <= \(CFIResourcePolicy.maximumStructuralBytes)
                 THEN ZANNOTATIONLOCATION
                 ELSE NULL
               END
        FROM ZAEANNOTATION
        WHERE Z_PK=?
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        func text(_ index: Int32) -> String? {
            switch sqlite3_column_type(statement, index) {
            case SQLITE_NULL:
                return nil
            case SQLITE_TEXT:
                return try? decodeSQLiteText(statement, at: index)
            default:
                return nil
            }
        }

        let assetID = text(0)
        let rawCFI = text(1)
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return Annotation.appleBooksURL(rawAssetID: assetID, rawCFI: rawCFI)
    }

    private static func validateNoteTarget(_ note: String?) throws {
        guard let note else { return }
        guard AnnotationContentSemantics.hasContent(note),
              note.count <= 10_000,
              note.utf8.count <= 64 * 1_024 else {
            throw AnnotationWriteError.invalidNoteLength
        }
    }

    private static func noteHistoryEffect(_ previousNote: String?) -> MutationHistoryEffect? {
        guard let previousNote else { return .annotationNote(previous: nil) }
        guard AnnotationContentSemantics.hasContent(previousNote),
              previousNote.count <= 10_000,
              previousNote.utf8.count <= 64 * 1_024 else {
            return nil
        }
        return .annotationNote(previous: previousNote)
    }

    private static func currentNote(localPK: Int64, on handle: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE Z_PK=? ORDER BY rowid LIMIT 2",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw AnnotationWriteError.writeFailed
        }
        let note: String?
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_NULL:
            note = nil
        case SQLITE_TEXT:
            do {
                note = try decodeSQLiteText(statement, at: 0)
            } catch {
                throw AnnotationWriteError.writeFailed
            }
        default:
            throw AnnotationWriteError.writeFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnnotationWriteError.writeFailed }
        return note
    }

    private static func domainData(target: Target, changed: Bool) -> MutationDomainData {
        MutationDomainData(
            localPK: target.localPK,
            stableID: target.stableID,
            changed: changed,
            appleBooksURL: target.appleBooksURL
        )
    }

    private static func applyNote(_ note: String?, to localPK: Int64, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE ZAEANNOTATION SET ZANNOTATIONNOTE=?,ZANNOTATIONMODIFICATIONDATE=?,ZFUTUREPROOFING6=?,Z_OPT=Z_OPT+1 WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        let noteBind = note.map { bind($0, to: statement, index: 1) } ?? sqlite3_bind_null(statement, 1)
        guard noteBind == SQLITE_OK,
              let now = CoreDataTime.seconds(from: Date()),
              sqlite3_bind_double(statement, 2, now) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, now) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func applyState(_ state: TargetState, to localPK: Int64, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=?,ZANNOTATIONMODIFICATIONDATE=?,ZFUTUREPROOFING6=?,Z_OPT=Z_OPT+1 WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        let deleted: Int32 = state == .tombstone ? 1 : 0
        guard sqlite3_bind_int(statement, 1, deleted) == SQLITE_OK,
              let now = CoreDataTime.seconds(from: Date()),
              sqlite3_bind_double(statement, 2, now) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, now) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func verifyNote(
        _ note: String?,
        target: Target,
        requireMutationMetadata: Bool,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = "SELECT Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONNOTE,ZANNOTATIONMODIFICATIONDATE,ZFUTUREPROOFING6 FROM ZAEANNOTATION WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, target.localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == target.entityID,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 2) == 0 else {
            throw AnnotationWriteError.writeFailed
        }

        let noteType = sqlite3_column_type(statement, 3)
        switch note {
        case nil where noteType == SQLITE_NULL:
            break
        case let .some(expected) where noteType == SQLITE_TEXT:
            let stored: String
            do {
                stored = try decodeSQLiteText(statement, at: 3)
            } catch {
                throw AnnotationWriteError.writeFailed
            }
            guard stored == expected else { throw AnnotationWriteError.writeFailed }
        default:
            throw AnnotationWriteError.writeFailed
        }

        if requireMutationMetadata {
            guard sqlite3_column_type(statement, 4) == SQLITE_FLOAT,
                  sqlite3_column_type(statement, 5) == SQLITE_TEXT else {
                throw AnnotationWriteError.writeFailed
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnnotationWriteError.writeFailed }
    }

    private static func verifyState(
        _ state: TargetState,
        target: Target,
        requireMutationMetadata: Bool,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = "SELECT Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONMODIFICATIONDATE,ZFUTUREPROOFING6 FROM ZAEANNOTATION WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        let expectedDeleted: Int64 = state == .tombstone ? 1 : 0
        guard sqlite3_bind_int64(statement, 1, target.localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == target.entityID,
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 2) == expectedDeleted else {
            throw AnnotationWriteError.writeFailed
        }
        if requireMutationMetadata {
            guard sqlite3_column_type(statement, 3) == SQLITE_FLOAT,
                  sqlite3_column_type(statement, 4) == SQLITE_TEXT else {
                throw AnnotationWriteError.writeFailed
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw AnnotationWriteError.writeFailed }
    }

    func pendingCloudChangeCount() throws -> Int {
        guard let cloudSynchronizer else { throw AppleBooksCloudSyncError.unavailable }
        return try cloudSynchronizer.pendingCount()
    }

    func waitForPendingCloudAcknowledgement() throws {
        guard let cloudSynchronizer else { throw AppleBooksCloudSyncError.unavailable }
        try cloudSynchronizer.waitForPendingAcknowledgement()
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        bindSQLiteText(value, to: statement, at: index)
    }
}

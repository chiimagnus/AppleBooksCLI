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

public enum AnnotationCreateError: Error, Equatable, Sendable {
    case projectionUnavailable
    case applicationVersionUnavailable
    case conflict
    case sourceChanged
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
    private let creationProjector: AnnotationCloudProjector?
    private let annotationsDatabase: URL
    private let booksApp: BooksAppController

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksApp: BooksAppController = .live,
        cloudProjector: AnnotationCloudProjector? = nil,
        cloudSynchronizer: AnnotationCloudSynchronizer? = nil,
        creationProjector: AnnotationCloudProjector? = nil
    ) {
        coordinator = MutationCoordinator(
            database: database,
            backupRoot: backupRoot,
            keep: keep,
            booksApp: booksApp
        )
        self.cloudProjector = cloudProjector
        self.cloudSynchronizer = cloudSynchronizer
        self.creationProjector = creationProjector
        annotationsDatabase = database
        self.booksApp = booksApp
    }


    private struct Creation {
        let localPK: Int64
        let uuid: String
        let changed: Bool
    }

    func repairCreationProjection(uuid: String) throws -> AnnotationProjectionRepairResult {
        guard let creationProjector else { throw AnnotationCreateError.projectionUnavailable }
        guard PublicStableIdentityPolicy.isEligible(uuid) else { throw AnnotationWriteError.annotationMissing }
        let connection = try SQLiteConnection.readOnly(path: annotationsDatabase.path)
        defer { try? connection.close() }
        let stmt = try connection.prepare("""
            SELECT Z_PK,ZANNOTATIONTYPE,ZANNOTATIONDELETED,ZANNOTATIONASSETID FROM ZAEANNOTATION
            WHERE ZANNOTATIONUUID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2
            """)
        try stmt.bind(uuid, at: 1)
        guard try stmt.step() else { throw AnnotationWriteError.annotationMissing }
        let row = try SQLiteRow(statement: stmt)
        guard let pk = try row.int64("Z_PK"), pk > 0,
              try row.int64("ZANNOTATIONTYPE") == 2,
              try row.int64("ZANNOTATIONDELETED") == 0,
              let assetID = try row.text("ZANNOTATIONASSETID"),
              PublicStableIdentityPolicy.isEligible(assetID),
              try stmt.step() == false else {
            throw AnnotationWriteError.annotationNotWritable
        }
        try creationProjector.validateCreationTarget(assetID: assetID)
        let originalState = booksApp.state()
        try booksApp.terminateAndWait()
        do {
            try creationProjector.project(localPK: pk)
        } catch {
            try? booksApp.restore(originalState)
            throw error
        }
        var warnings: [String] = []
        do { try booksApp.restore(originalState) }
        catch { warnings.append("books_state_restore_failed") }
        return AnnotationProjectionRepairResult(annotationUUID: uuid, verified: true, warningCodes: warnings)
    }

    static func previewExistingUUID(
        assetID: String, selection: EPUBAnnotationSelection,
        note: String?, color: AnnotationColor, underline: Bool, on handle: OpaquePointer
    ) throws -> String? {
        try validateNoteTarget(note)
        try WriteSchemaGuard.validateTable(
            .annotations, required: WriteSchemaGuard.annotationKnownColumns, inserting: true, on: handle
        )
        _ = try WriteSchemaGuard.entity(named: entityName, on: handle)
        return try findCreation(
            assetID: assetID, selection: selection, note: note,
            color: color, underline: underline, on: handle
        )?.uuid
    }

    func create(
        assetID: String, selection: EPUBAnnotationSelection, note: String?,
        color: AnnotationColor, underline: Bool = false,
        verifySource: @escaping () throws -> EPUBAnnotationSelection,
        syncCloud: Bool = false
    ) throws -> MutationResult {
        try Self.validateNoteTarget(note)
        guard let creationProjector else { throw AnnotationCreateError.projectionUnavailable }
        guard PublicStableIdentityPolicy.isEligible(assetID),
              (selection.bookIdentity == nil || selection.bookIdentity?.assetID == assetID),
              selection.selectedText.isEmpty == false,
              selection.representativeText.isEmpty == false,
              CFIResourcePolicy.allowsStructuralParsing(selection.cfi) else {
            throw AnnotationCreateError.sourceChanged
        }
        func validate(_ handle: OpaquePointer) throws {
            guard try verifySource() == selection else { throw AnnotationCreateError.sourceChanged }
            try creationProjector.validateCreationTarget(assetID: assetID)
            try WriteSchemaGuard.validateTable(
                .annotations, required: WriteSchemaGuard.annotationKnownColumns, inserting: true, on: handle
            )
            _ = try WriteSchemaGuard.entity(named: Self.entityName, on: handle)
        }
        func existing(_ handle: OpaquePointer) throws -> Creation? {
            try Self.findCreation(
                assetID: assetID, selection: selection, note: note,
                color: color, underline: underline, on: handle
            )
        }
        return try coordinator.perform(
            preflight: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.writeFailed }
                try validate(handle)
                _ = try existing(handle)
            },
            quietDecision: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.writeFailed }
                try validate(handle)
                if let duplicate = try existing(handle) {
                    return .noChange(MutationDomainData(
                        localPK: duplicate.localPK, stableID: duplicate.uuid, changed: false,
                        appleBooksURL: Annotation.appleBooksURL(rawAssetID: assetID, rawCFI: selection.cfi)
                    ))
                }
                return .needsMutation
            },
            avoidBooksQuitForReadOnlyNoOp: true,
            revalidate: { handle in try validate(handle) },
            mutation: { handle in
                if let duplicate = try existing(handle) { return duplicate }
                let allocated = try CoreDataPrimaryKey.allocate(
                    entityName: Self.entityName, table: .annotations, on: handle
                )
                let uuid = UUID().uuidString
                try Self.insertCreation(
                    localPK: allocated.localPK, entityID: allocated.entityID,
                    uuid: uuid, assetID: assetID, selection: selection,
                    note: note, color: color, underline: underline, on: handle
                )
                return Creation(localPK: allocated.localPK, uuid: uuid, changed: true)
            },
            invariant: { handle, record in
                guard try verifySource() == selection else {
                    throw AnnotationCreateError.sourceChanged
                }
                try Self.verifyCreation(
                    record, assetID: assetID, selection: selection,
                    note: note, color: color, underline: underline, on: handle
                )
            },
            domainData: { record in
                MutationDomainData(
                    localPK: record.localPK, stableID: record.uuid, changed: record.changed,
                    appleBooksURL: Annotation.appleBooksURL(rawAssetID: assetID, rawCFI: selection.cfi)
                )
            },
            cloudProjection: { record in
                try creationProjector.project(localPK: record.localPK)
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { record, onLaunch in
                    try synchronizer.sync(localPK: record.localPK, onTemporaryBooksLaunch: onLaunch)
                }
            },
            readBack: { connection, record in
                guard let handle = connection.handle else { throw AnnotationWriteError.writeFailed }
                try Self.verifyCreation(
                    record, assetID: assetID, selection: selection,
                    note: note, color: color, underline: underline, on: handle
                )
            }
        )
    }

    private static func findCreation(
        assetID: String, selection: EPUBAnnotationSelection,
        note: String?, color: AnnotationColor, underline: Bool,
        on handle: OpaquePointer
    ) throws -> Creation? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, """
            SELECT Z_PK,ZANNOTATIONUUID,ZANNOTATIONTYPE,ZANNOTATIONDELETED,
                   ZANNOTATIONSTYLE,ZANNOTATIONISUNDERLINE,ZANNOTATIONSELECTEDTEXT,
                   ZANNOTATIONREPRESENTATIVETEXT,ZANNOTATIONNOTE,Z_OPT
            FROM ZAEANNOTATION WHERE ZANNOTATIONASSETID=? COLLATE BINARY
                AND ZANNOTATIONLOCATION=? COLLATE BINARY AND ZANNOTATIONTYPE!=3
            ORDER BY Z_PK LIMIT 2
            """, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard bind(assetID, to: stmt, index: 1) == SQLITE_OK,
              bind(selection.cfi, to: stmt, index: 2) == SQLITE_OK else {
            throw AnnotationWriteError.writeFailed
        }
        let first = sqlite3_step(stmt)
        if first == SQLITE_DONE { return nil }
        guard first == SQLITE_ROW else { throw AnnotationWriteError.writeFailed }
        guard sqlite3_column_type(stmt, 1) == SQLITE_TEXT,
              sqlite3_column_type(stmt, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 2) == 2,
              sqlite3_column_type(stmt, 3) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 3) == 0,
              sqlite3_column_type(stmt, 4) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 4) == color.rawValue,
              sqlite3_column_type(stmt, 5) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 5) == (underline ? 1 : 0),
              sqlite3_column_type(stmt, 6) == SQLITE_TEXT,
              sqlite3_column_type(stmt, 7) == SQLITE_TEXT,
              sqlite3_column_type(stmt, 9) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 9) > 0,
              (try? decodeSQLiteText(stmt, at: 6)) == selection.selectedText,
              (try? decodeSQLiteText(stmt, at: 7)) == selection.representativeText else {
            throw AnnotationCreateError.conflict
        }
        let uuid = try decodeSQLiteText(stmt, at: 1)
        guard PublicStableIdentityPolicy.isEligible(uuid) else {
            throw AnnotationCreateError.conflict
        }
        switch (note, sqlite3_column_type(stmt, 8)) {
        case (nil, SQLITE_NULL): break
        case let (.some(value), kind) where kind == SQLITE_TEXT:
            guard (try? decodeSQLiteText(stmt, at: 8)) == value else {
                throw AnnotationCreateError.conflict
            }
        default: throw AnnotationCreateError.conflict
        }
        guard sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(stmt, 0) > 0 else {
            throw AnnotationCreateError.conflict
        }
        let localPK = sqlite3_column_int64(stmt, 0)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw AnnotationCreateError.conflict
        }
        let entity = try WriteSchemaGuard.entity(named: entityName, on: handle)
        try WriteSchemaGuard.validateExistingEntity(
            table: .annotations, localPK: localPK, expectedEntityID: entity.entityID, on: handle
        )
        return Creation(localPK: localPK, uuid: uuid, changed: false)
    }

    private static func insertCreation(
        localPK: Int64, entityID: Int64, uuid: String, assetID: String,
        selection: EPUBAnnotationSelection, note: String?, color: AnnotationColor,
        underline: Bool, on handle: OpaquePointer
    ) throws {
        guard let time = CoreDataTime.seconds(from: Date()) else {
            throw AnnotationWriteError.writeFailed
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, """
            INSERT INTO ZAEANNOTATION(
                Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONISUNDERLINE,
                ZANNOTATIONSTYLE,ZANNOTATIONTYPE,ZPLABSOLUTEPHYSICALLOCATION,
                ZPLLOCATIONRANGESTART,ZPLLOCATIONRANGEEND,
                ZANNOTATIONCREATIONDATE,ZANNOTATIONMODIFICATIONDATE,
                ZANNOTATIONASSETID,ZANNOTATIONCREATORIDENTIFIER,ZANNOTATIONLOCATION,
                ZANNOTATIONNOTE,ZANNOTATIONREPRESENTATIVETEXT,ZANNOTATIONSELECTEDTEXT,
                ZANNOTATIONUUID,ZFUTUREPROOFING11,ZFUTUREPROOFING6
            ) VALUES(?,?,1,0,?,?,2,0,0,0,?,? ,?,'com~apple~iBooks',?,?,?,?,?,?,?)
            """, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            if let stmt { sqlite3_finalize(stmt) }
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_int64(stmt, 1, localPK) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, entityID) == SQLITE_OK,
              sqlite3_bind_int(stmt, 3, underline ? 1 : 0) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 4, color.rawValue) == SQLITE_OK,
              sqlite3_bind_double(stmt, 5, time) == SQLITE_OK,
              sqlite3_bind_double(stmt, 6, time) == SQLITE_OK,
              bind(assetID, to: stmt, index: 7) == SQLITE_OK,
              bind(selection.cfi, to: stmt, index: 8) == SQLITE_OK,
              (note.map { bind($0, to: stmt, index: 9) } ?? sqlite3_bind_null(stmt, 9)) == SQLITE_OK,
              bind(selection.representativeText, to: stmt, index: 10) == SQLITE_OK,
              bind(selection.selectedText, to: stmt, index: 11) == SQLITE_OK,
              bind(uuid, to: stmt, index: 12) == SQLITE_OK,
              bind(String(time), to: stmt, index: 13) == SQLITE_OK,
              bind(String(time), to: stmt, index: 14) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func verifyCreation(
        _ created: Creation, assetID: String, selection: EPUBAnnotationSelection,
        note: String?, color: AnnotationColor, underline: Bool, on handle: OpaquePointer
    ) throws {
        guard let match = try findCreation(
            assetID: assetID, selection: selection, note: note,
            color: color, underline: underline, on: handle
        ), match.localPK == created.localPK, match.uuid == created.uuid else {
            throw AnnotationWriteError.writeFailed
        }
        let entity = try WriteSchemaGuard.entity(named: entityName, on: handle)
        try WriteSchemaGuard.validateExistingEntity(
            table: .annotations, localPK: created.localPK,
            expectedEntityID: entity.entityID, on: handle
        )
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
        let projection = CloudProjectionResourcePolicy.exactTextProjection("ZANNOTATIONUUID")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT \(projection) FROM ZAEANNOTATION WHERE Z_PK=? ORDER BY rowid LIMIT 2",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let uuid: String
        do {
            switch try CloudProjectionResourcePolicy.exactText(
                statement,
                storageIndex: 0,
                lengthIndex: 1,
                payloadIndex: 2
            ) {
            case let .value(value) where PublicStableIdentityPolicy.isEligible(value):
                uuid = value
            case .value, .null, .oversized:
                return nil
            }
        } catch {
            return nil
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { return nil }
        return uuid
    }

    private static func appleBooksURL(localPK: Int64, on handle: OpaquePointer) -> String? {
        var statement: OpaquePointer?
        let assetProjection = CloudProjectionResourcePolicy.exactTextProjection("ZANNOTATIONASSETID")
        let sql = """
        SELECT \(assetProjection),
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

        let assetID: String?
        do {
            switch try CloudProjectionResourcePolicy.exactText(
                statement,
                storageIndex: 0,
                lengthIndex: 1,
                payloadIndex: 2
            ) {
            case let .value(value) where value.isEmpty == false:
                assetID = value
            case .value, .null, .oversized:
                assetID = nil
            }
        } catch {
            assetID = nil
        }
        let rawCFI: String?
        switch sqlite3_column_type(statement, 3) {
        case SQLITE_NULL:
            rawCFI = nil
        case SQLITE_TEXT:
            rawCFI = try? decodeSQLiteText(statement, at: 3)
        default:
            rawCFI = nil
        }
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

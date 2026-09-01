import Foundation
import SQLite3

enum AnnotationWriteError: Error, Equatable {
    case invalidNoteLength
    case annotationMissing
    case annotationDeletedOrUnknown
    case writeFailed
}

struct AnnotationWriter {
    private static let entityName = "AEAnnotation"
    private static let updateColumns: Set<String> = [
        "Z_PK",
        "Z_ENT",
        "Z_OPT",
        "ZANNOTATIONDELETED",
        "ZANNOTATIONNOTE",
        "ZANNOTATIONMODIFICATIONDATE",
    ]
    private static let deleteColumns: Set<String> = [
        "Z_PK",
        "Z_ENT",
        "Z_OPT",
        "ZANNOTATIONDELETED",
        "ZANNOTATIONMODIFICATIONDATE",
    ]

    private enum Selector {
        case localPK(Int64)
        case uuid(String)
    }

    private struct Target {
        let localPK: Int64
        let entityID: Int64
        let stableID: String?
    }

    private let coordinator: MutationCoordinator

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksApp: BooksAppController = .live
    ) {
        coordinator = MutationCoordinator(
            database: database,
            backupRoot: backupRoot,
            keep: keep,
            booksApp: booksApp
        )
    }

    func updateNote(localPK: Int64, note: String) throws -> MutationResult {
        try updateNote(.localPK(localPK), note: note)
    }

    func updateNote(uuid: String, note: String) throws -> MutationResult {
        try updateNote(.uuid(uuid), note: note)
    }

    func delete(localPK: Int64) throws -> MutationResult {
        try delete(.localPK(localPK))
    }

    func delete(uuid: String) throws -> MutationResult {
        try delete(.uuid(uuid))
    }

    private func updateNote(_ selector: Selector, note: String) throws -> MutationResult {
        guard note.isEmpty == false, note.count <= 10_000 else {
            throw AnnotationWriteError.invalidNoteLength
        }

        return try coordinator.perform(
            preflight: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.validateSchema(for: selector, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            revalidate: { handle in
                try Self.validateSchema(for: selector, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            mutation: { handle in
                let target = try Self.resolve(selector, on: handle)
                try Self.applyNote(note, to: target.localPK, on: handle)
                return target
            },
            invariant: { handle, target in
                try Self.verifyNote(note, target: target, on: handle)
            },
            domainData: { target in
                MutationDomainData(localPK: target.localPK, stableID: target.stableID, changed: true)
            },
            readBack: { connection, target in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.verifyNote(note, target: target, on: handle)
            }
        )
    }

    private func delete(_ selector: Selector) throws -> MutationResult {
        try coordinator.perform(
            preflight: { connection in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.validateSchema(for: selector, required: Self.deleteColumns, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            revalidate: { handle in
                try Self.validateSchema(for: selector, required: Self.deleteColumns, on: handle)
                _ = try Self.resolve(selector, on: handle)
            },
            mutation: { handle in
                let target = try Self.resolve(selector, on: handle)
                try Self.applyDelete(to: target.localPK, on: handle)
                return target
            },
            invariant: { handle, target in
                try Self.verifyDeleted(target: target, on: handle)
            },
            domainData: { target in
                MutationDomainData(localPK: target.localPK, stableID: target.stableID, changed: true)
            },
            readBack: { connection, target in
                guard let handle = connection.handle else { throw AnnotationWriteError.annotationMissing }
                try Self.verifyDeleted(target: target, on: handle)
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
        _ = try WriteSchemaGuard.entity(named: entityName, on: handle)
    }

    private static func resolve(_ selector: Selector, on handle: OpaquePointer) throws -> Target {
        let entity = try WriteSchemaGuard.entity(named: entityName, on: handle)
        let sql: String
        switch selector {
        case .localPK:
            sql = "SELECT Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE Z_PK=? ORDER BY rowid"
        case .uuid:
            sql = "SELECT Z_PK,Z_ENT,Z_OPT,ZANNOTATIONDELETED FROM ZAEANNOTATION WHERE ZANNOTATIONUUID=? COLLATE BINARY ORDER BY Z_PK"
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

        var rows: [(localPK: Int64, entityID: Int64?, optValid: Bool, deleted: Int64?)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let localPK = sqlite3_column_int64(statement, 0)
                let entityID = sqlite3_column_type(statement, 1) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 1) : nil
                let optValid = sqlite3_column_type(statement, 2) == SQLITE_INTEGER
                let deleted = sqlite3_column_type(statement, 3) == SQLITE_INTEGER ? sqlite3_column_int64(statement, 3) : nil
                rows.append((localPK, entityID, optValid, deleted))
            case SQLITE_DONE:
                break
            default:
                throw AnnotationWriteError.writeFailed
            }
            if sqlite3_data_count(statement) == 0 { break }
        }

        guard rows.isEmpty == false else { throw AnnotationWriteError.annotationMissing }
        if case .uuid = selector, rows.count > 1 {
            throw StableIdentityError.ambiguousAnnotationUUID
        }
        guard rows.count == 1 else { throw AnnotationWriteError.writeFailed }
        let row = rows[0]
        guard row.entityID == entity.entityID else {
            throw WriteSchemaGuardError.entityMismatch(WriteSchemaTable.annotations.rawValue)
        }
        guard row.optValid else { throw AnnotationWriteError.writeFailed }
        guard row.deleted == 0 else { throw AnnotationWriteError.annotationDeletedOrUnknown }

        let stableID: String?
        if case let .uuid(uuid) = selector {
            stableID = uuid
        } else {
            stableID = nil
        }
        return Target(localPK: row.localPK, entityID: entity.entityID, stableID: stableID)
    }

    private static func applyNote(_ note: String, to localPK: Int64, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE ZAEANNOTATION SET ZANNOTATIONNOTE=?,ZANNOTATIONMODIFICATIONDATE=?,Z_OPT=Z_OPT+1 WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard bind(note, to: statement, index: 1) == SQLITE_OK,
              let now = CoreDataTime.seconds(from: Date()),
              sqlite3_bind_double(statement, 2, now) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func applyDelete(to localPK: Int64, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "UPDATE ZAEANNOTATION SET ZANNOTATIONDELETED=1,ZANNOTATIONMODIFICATIONDATE=?,Z_OPT=Z_OPT+1 WHERE Z_PK=?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw AnnotationWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard let now = CoreDataTime.seconds(from: Date()),
              sqlite3_bind_double(statement, 1, now) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func verifyNote(_ note: String, target: Target, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "SELECT Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONNOTE,ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION WHERE Z_PK=?"
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
              sqlite3_column_int64(statement, 2) == 0,
              sqlite3_column_type(statement, 3) == SQLITE_TEXT,
              let rawNote = sqlite3_column_text(statement, 3),
              String(cString: rawNote) == note,
              sqlite3_column_type(statement, 4) == SQLITE_FLOAT,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func verifyDeleted(target: Target, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = "SELECT Z_ENT,Z_OPT,ZANNOTATIONDELETED,ZANNOTATIONMODIFICATIONDATE FROM ZAEANNOTATION WHERE Z_PK=?"
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
              sqlite3_column_int64(statement, 2) == 1,
              sqlite3_column_type(statement, 3) == SQLITE_FLOAT,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw AnnotationWriteError.writeFailed
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

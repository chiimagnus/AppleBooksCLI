import Foundation
import SQLite3

struct CoreDataEntityMetadata: Equatable {
    let entityID: Int64
    let maxPK: Int64
}

enum WriteSchemaGuardError: Error, Equatable {
    case missingTable(String)
    case missingRequiredColumns(table: String, columns: [String])
    case unknownRequiredColumns(table: String, columns: [String])
    case missingEntity(String)
    case duplicateEntity(String)
    case invalidEntity(String)
    case targetMissing(String)
    case entityMismatch(String)
}

enum WriteSchemaTable: String {
    case collections = "ZBKCOLLECTION"
    case members = "ZBKCOLLECTIONMEMBER"
    case books = "ZBKLIBRARYASSET"
    case primaryKey = "Z_PRIMARYKEY"

    var writerKnownColumns: Set<String>? {
        switch self {
        case .collections:
            [
                "Z_PK", "Z_ENT", "Z_OPT", "ZDELETEDFLAG", "ZHIDDEN", "ZPLACEHOLDER",
                "ZSORTKEY", "ZSORTMODE", "ZVIEWMODE", "ZLASTMODIFICATION", "ZLOCALMODDATE",
                "ZCOLLECTIONID", "ZDETAILS", "ZTITLE",
            ]
        case .members:
            [
                "Z_PK", "Z_ENT", "Z_OPT", "ZSORTKEY", "ZASSET", "ZCOLLECTION",
                "ZLOCALMODDATE", "ZASSETID", "ZTEMPORARYASSETID",
            ]
        case .books, .primaryKey:
            nil
        }
    }
}

enum WriteSchemaGuard {
    static let collectionKnownColumns = WriteSchemaTable.collections.writerKnownColumns!
    static let memberKnownColumns = WriteSchemaTable.members.writerKnownColumns!

    static func validateTable(
        _ table: WriteSchemaTable,
        required: Set<String>,
        inserting: Bool,
        on connection: SQLiteConnection
    ) throws {
        guard let handle = connection.handle else { throw WriteSchemaGuardError.missingTable(table.rawValue) }
        try validateTable(table, required: required, inserting: inserting, on: handle)
    }

    static func validateTable(
        _ table: WriteSchemaTable,
        required: Set<String>,
        inserting: Bool,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "SELECT name, [notnull] AS is_not_null FROM pragma_table_info(?) ORDER BY cid",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw WriteSchemaGuardError.missingTable(table.rawValue)
        }
        defer { sqlite3_finalize(statement) }
        guard bind(table.rawValue, to: statement, index: 1) == SQLITE_OK else {
            throw WriteSchemaGuardError.missingTable(table.rawValue)
        }

        var columns = Set<String>()
        var unknownRequired: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let rawName = sqlite3_column_text(statement, 0) else { continue }
                let name = String(cString: rawName)
                columns.insert(name)
                if inserting,
                   let known = table.writerKnownColumns,
                   known.contains(name) == false,
                   sqlite3_column_int64(statement, 1) == 1 {
                    unknownRequired.append(name)
                }
            case SQLITE_DONE:
                break
            default:
                throw WriteSchemaGuardError.missingTable(table.rawValue)
            }
            if sqlite3_data_count(statement) == 0 { break }
        }
        guard columns.isEmpty == false else { throw WriteSchemaGuardError.missingTable(table.rawValue) }

        let missing = required.subtracting(columns).sorted()
        guard missing.isEmpty else {
            throw WriteSchemaGuardError.missingRequiredColumns(table: table.rawValue, columns: missing)
        }
        guard unknownRequired.isEmpty else {
            throw WriteSchemaGuardError.unknownRequiredColumns(table: table.rawValue, columns: unknownRequired.sorted())
        }
    }

    static func entity(named name: String, on connection: SQLiteConnection) throws -> CoreDataEntityMetadata {
        guard let handle = connection.handle else { throw WriteSchemaGuardError.missingEntity(name) }
        return try entity(named: name, on: handle)
    }

    static func entity(named name: String, on handle: OpaquePointer) throws -> CoreDataEntityMetadata {
        try validateTable(.primaryKey, required: ["Z_NAME", "Z_ENT", "Z_MAX"], inserting: false, on: handle)
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = ? ORDER BY rowid",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw WriteSchemaGuardError.missingEntity(name)
        }
        defer { sqlite3_finalize(statement) }
        guard bind(name, to: statement, index: 1) == SQLITE_OK else {
            throw WriteSchemaGuardError.missingEntity(name)
        }

        var rows: [(Int64?, Int64?)] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let entityID = sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
                let maxPK = sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 1)
                rows.append((entityID, maxPK))
            case SQLITE_DONE:
                break
            default:
                throw WriteSchemaGuardError.invalidEntity(name)
            }
            if sqlite3_data_count(statement) == 0 { break }
        }
        guard rows.isEmpty == false else { throw WriteSchemaGuardError.missingEntity(name) }
        guard rows.count == 1 else { throw WriteSchemaGuardError.duplicateEntity(name) }
        guard let entityID = rows[0].0, entityID > 0,
              let maxPK = rows[0].1, maxPK >= 0 else {
            throw WriteSchemaGuardError.invalidEntity(name)
        }
        return CoreDataEntityMetadata(entityID: entityID, maxPK: maxPK)
    }

    static func validateExistingEntity(
        table: WriteSchemaTable,
        localPK: Int64,
        expectedEntityID: Int64,
        on connection: SQLiteConnection
    ) throws {
        guard let handle = connection.handle else { throw WriteSchemaGuardError.targetMissing(table.rawValue) }
        try validateExistingEntity(table: table, localPK: localPK, expectedEntityID: expectedEntityID, on: handle)
    }

    static func validateExistingEntity(
        table: WriteSchemaTable,
        localPK: Int64,
        expectedEntityID: Int64,
        on handle: OpaquePointer
    ) throws {
        precondition(table == .collections || table == .members)
        try validateTable(table, required: ["Z_PK", "Z_ENT"], inserting: false, on: handle)
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "SELECT Z_ENT FROM \(table.rawValue) WHERE Z_PK = ?",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw WriteSchemaGuardError.targetMissing(table.rawValue)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw WriteSchemaGuardError.targetMissing(table.rawValue)
        }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == expectedEntityID,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw WriteSchemaGuardError.entityMismatch(table.rawValue)
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

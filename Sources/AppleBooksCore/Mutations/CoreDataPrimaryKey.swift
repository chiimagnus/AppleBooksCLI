import SQLite3

struct CoreDataPrimaryKeyAllocation: Equatable {
    let entityID: Int64
    let localPK: Int64
}

enum CoreDataPrimaryKeyError: Error, Equatable {
    case transactionRequired
    case unsupportedTable
    case missingEntity
    case duplicateEntity
    case invalidEntity
    case allocationOverflow
    case updateFailed
}

enum CoreDataPrimaryKey {
    static func allocate(
        entityName: String,
        table: WriteSchemaTable,
        on handle: OpaquePointer
    ) throws -> CoreDataPrimaryKeyAllocation {
        guard sqlite3_get_autocommit(handle) == 0 else {
            throw CoreDataPrimaryKeyError.transactionRequired
        }
        guard table == .collections || table == .members else {
            throw CoreDataPrimaryKeyError.unsupportedTable
        }

        let entity = try readEntity(named: entityName, on: handle)
        let tableMax = try maximumPrimaryKey(in: table, on: handle)
        let base = max(entity.maxPK, tableMax)
        guard base < Int64.max else { throw CoreDataPrimaryKeyError.allocationOverflow }
        let next = base + 1

        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_NAME = ? AND Z_ENT = ? AND Z_MAX = ?",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CoreDataPrimaryKeyError.updateFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, next) == SQLITE_OK,
              bind(entityName, to: statement, index: 2) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, entity.entityID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, entity.maxPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw CoreDataPrimaryKeyError.updateFailed
        }
        return CoreDataPrimaryKeyAllocation(entityID: entity.entityID, localPK: next)
    }

    private static func readEntity(named name: String, on handle: OpaquePointer) throws -> CoreDataEntityMetadata {
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
            throw CoreDataPrimaryKeyError.missingEntity
        }
        defer { sqlite3_finalize(statement) }
        guard bind(name, to: statement, index: 1) == SQLITE_OK else {
            throw CoreDataPrimaryKeyError.missingEntity
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
                throw CoreDataPrimaryKeyError.invalidEntity
            }
            if sqlite3_data_count(statement) == 0 { break }
        }
        guard rows.isEmpty == false else { throw CoreDataPrimaryKeyError.missingEntity }
        guard rows.count == 1 else { throw CoreDataPrimaryKeyError.duplicateEntity }
        guard let entityID = rows[0].0, entityID > 0,
              let maxPK = rows[0].1, maxPK >= 0 else {
            throw CoreDataPrimaryKeyError.invalidEntity
        }
        return CoreDataEntityMetadata(entityID: entityID, maxPK: maxPK)
    }

    private static func maximumPrimaryKey(in table: WriteSchemaTable, on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(handle, "SELECT MAX(Z_PK) FROM \(table.rawValue)", -1, &statement, nil)
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CoreDataPrimaryKeyError.invalidEntity
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CoreDataPrimaryKeyError.invalidEntity }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

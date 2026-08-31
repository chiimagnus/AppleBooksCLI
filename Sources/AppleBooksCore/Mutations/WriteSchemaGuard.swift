import Foundation

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
        let statement = try connection.prepare(
            "SELECT name, [notnull] AS is_not_null FROM pragma_table_info(?) ORDER BY cid"
        )
        try statement.bind(table.rawValue, at: 1)

        var columns = Set<String>()
        var unknownRequired: [String] = []
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            guard let name = try row.text("name") else { continue }
            columns.insert(name)
            if inserting,
               let known = table.writerKnownColumns,
               known.contains(name) == false,
               try row.int64("is_not_null") == 1 {
                unknownRequired.append(name)
            }
        }
        guard columns.isEmpty == false else {
            throw WriteSchemaGuardError.missingTable(table.rawValue)
        }

        let missing = required.subtracting(columns).sorted()
        guard missing.isEmpty else {
            throw WriteSchemaGuardError.missingRequiredColumns(table: table.rawValue, columns: missing)
        }
        guard unknownRequired.isEmpty else {
            throw WriteSchemaGuardError.unknownRequiredColumns(
                table: table.rawValue,
                columns: unknownRequired.sorted()
            )
        }
    }

    static func entity(named name: String, on connection: SQLiteConnection) throws -> CoreDataEntityMetadata {
        try validateTable(
            .primaryKey,
            required: ["Z_NAME", "Z_ENT", "Z_MAX"],
            inserting: false,
            on: connection
        )
        let statement = try connection.prepare(
            "SELECT Z_ENT, Z_MAX FROM Z_PRIMARYKEY WHERE Z_NAME = ? ORDER BY rowid"
        )
        try statement.bind(name, at: 1)

        var rows: [(Int64?, Int64?)] = []
        while try statement.step() {
            let row = try SQLiteRow(statement: statement)
            rows.append((try row.int64("Z_ENT"), try row.int64("Z_MAX")))
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
        precondition(table == .collections || table == .members)
        try validateTable(table, required: ["Z_PK", "Z_ENT"], inserting: false, on: connection)
        let statement = try connection.prepare(
            "SELECT Z_ENT FROM \(table.rawValue) WHERE Z_PK = ?"
        )
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { throw WriteSchemaGuardError.targetMissing(table.rawValue) }
        let row = try SQLiteRow(statement: statement)
        guard let entityID = try row.int64("Z_ENT"), entityID == expectedEntityID else {
            throw WriteSchemaGuardError.entityMismatch(table.rawValue)
        }
        guard try statement.step() == false else {
            throw WriteSchemaGuardError.entityMismatch(table.rawValue)
        }
    }
}

import Foundation
import SQLite3

enum CollectionWriteError: Error, Equatable {
    case invalidTitle
    case collectionMissing
    case collectionDeletedOrUnknown
    case collectionIdentityUnavailable
    case collectionNotEditable
    case bookMissing
    case bookAssetIDUnavailable
    case writeFailed
}

enum CollectionWriteScope {
    case collection
    case membership
}

struct CollectionWriteTarget: Equatable {
    let localPK: Int64
}

struct CollectionWriter {
    private static let membershipEditableSystemID = "Want_To_Read_Collection_ID"
    private static let collectionEntityName = "BKCollection"
    private static let memberEntityName = "BKCollectionMember"
    private static let sortKeyStep: Int64 = 10_000
    private static let defaultSortMode: Int64 = 6

    private let coordinator: MutationCoordinator

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksIsRunning: @escaping () -> Bool = isBooksAppRunning
    ) {
        coordinator = MutationCoordinator(
            database: database,
            backupRoot: backupRoot,
            keep: keep,
            booksIsRunning: booksIsRunning
        )
    }

    func createCollection(title: String, details: String? = nil) throws -> Collection {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else { throw CollectionWriteError.invalidTitle }

        return try coordinator.performAndReadBack(
            preflight: { connection in
                try Self.validateCreateSchema(on: connection)
            },
            revalidate: { handle in
                try Self.validateCreateSchema(on: handle)
            },
            mutation: { handle in
                let allocation = try CoreDataPrimaryKey.allocate(
                    entityName: Self.collectionEntityName,
                    table: .collections,
                    on: handle
                )
                let maxSort = try Self.maximumPositiveSortKey(on: handle)
                guard maxSort <= Int64.max - Self.sortKeyStep else { throw CollectionWriteError.writeFailed }
                let sortKey = maxSort + Self.sortKeyStep
                let timestamp = CoreDataTime.seconds(from: Date())!
                let collectionID = UUID().uuidString.uppercased()
                try Self.insertCollection(
                    localPK: allocation.localPK,
                    entityID: allocation.entityID,
                    sortKey: sortKey,
                    timestamp: timestamp,
                    collectionID: collectionID,
                    details: details,
                    title: normalizedTitle,
                    on: handle
                )
                return CreatedCollection(
                    localPK: allocation.localPK,
                    entityID: allocation.entityID,
                    title: normalizedTitle
                )
            },
            invariant: { handle, created in
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: created.localPK,
                    expectedEntityID: created.entityID,
                    on: handle
                )
            },
            committedLocalPK: { $0.localPK },
            readBack: { connection, created in
                guard let collection = try CollectionQueries(connection: connection).getByLocalPK(created.localPK),
                      collection.title == created.title else {
                    throw CollectionWriteError.writeFailed
                }
                return collection
            }
        )
    }

    func renameCollection(localPK: Int64, newTitle: String) throws -> Collection {
        let normalizedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else { throw CollectionWriteError.invalidTitle }

        return try coordinator.performAndReadBack(
            preflight: { connection in
                try Self.validateRenameSchema(on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.editableTarget(localPK: localPK, scope: .collection, on: handle)
            },
            revalidate: { handle in
                try Self.validateRenameSchema(on: handle)
                let entity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: localPK,
                    expectedEntityID: entity.entityID,
                    on: handle
                )
                _ = try Self.editableTarget(localPK: localPK, scope: .collection, on: handle)
            },
            mutation: { handle in
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.updateTitle(localPK: localPK, title: normalizedTitle, timestamp: timestamp, on: handle)
                return localPK
            },
            invariant: { handle, _ in
                _ = try Self.editableTarget(localPK: localPK, scope: .collection, on: handle)
            },
            committedLocalPK: { $0 },
            readBack: { connection, _ in
                guard let collection = try CollectionQueries(connection: connection).getByLocalPK(localPK),
                      collection.title == normalizedTitle else {
                    throw CollectionWriteError.writeFailed
                }
                return collection
            }
        )
    }

    func deleteCollection(localPK: Int64) throws {
        _ = try coordinator.perform(
            preflight: { connection in
                try Self.validateDeleteSchema(on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.editableTarget(localPK: localPK, scope: .collection, on: handle)
            },
            revalidate: { handle in
                try Self.validateDeleteSchema(on: handle)
                let entity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: localPK,
                    expectedEntityID: entity.entityID,
                    on: handle
                )
                _ = try Self.editableTarget(localPK: localPK, scope: .collection, on: handle)
            },
            mutation: { handle in
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.tombstoneCollection(localPK: localPK, timestamp: timestamp, on: handle)
                try Self.deleteMembershipRows(collectionLocalPK: localPK, on: handle)
                return localPK
            },
            invariant: { handle, _ in
                guard try Self.isDeleted(localPK: localPK, on: handle),
                      try Self.membershipCount(collectionLocalPK: localPK, on: handle) == 0 else {
                    throw CollectionWriteError.writeFailed
                }
            },
            committedLocalPK: { $0 },
            readBack: { connection, _ in
                guard let handle = connection.handle,
                      try Self.isDeleted(localPK: localPK, on: handle),
                      try Self.membershipCount(collectionLocalPK: localPK, on: handle) == 0 else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
    }

    func addBook(bookLocalPK: Int64, toCollectionLocalPK collectionLocalPK: Int64) throws -> Bool {
        let result = try coordinator.perform(
            preflight: { connection in
                try Self.validateMembershipSchema(inserting: true, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.editableTarget(localPK: collectionLocalPK, scope: .membership, on: handle)
                guard try Self.bookAssetID(localPK: bookLocalPK, on: handle) != nil else {
                    throw CollectionWriteError.bookAssetIDUnavailable
                }
            },
            revalidate: { handle in
                try Self.validateMembershipSchema(inserting: true, on: handle)
                let collectionEntity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: collectionLocalPK,
                    expectedEntityID: collectionEntity.entityID,
                    on: handle
                )
                _ = try Self.editableTarget(localPK: collectionLocalPK, scope: .membership, on: handle)
            },
            mutation: { handle in
                guard let assetID = try Self.bookAssetID(localPK: bookLocalPK, on: handle) else {
                    throw CollectionWriteError.bookAssetIDUnavailable
                }
                let memberEntity = try WriteSchemaGuard.entity(named: Self.memberEntityName, on: handle)
                try Self.validateMatchingMemberEntities(
                    collectionLocalPK: collectionLocalPK,
                    assetID: assetID,
                    expectedEntityID: memberEntity.entityID,
                    on: handle
                )
                if try Self.membershipCount(collectionLocalPK: collectionLocalPK, assetID: assetID, on: handle) > 0 {
                    return MembershipMutationResult(changed: false, assetID: assetID)
                }

                let allocation = try CoreDataPrimaryKey.allocate(
                    entityName: Self.memberEntityName,
                    table: .members,
                    on: handle
                )
                let maxSort = try Self.maximumMemberSortKey(collectionLocalPK: collectionLocalPK, on: handle)
                guard maxSort <= Int64.max - Self.sortKeyStep else { throw CollectionWriteError.writeFailed }
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.insertMember(
                    localPK: allocation.localPK,
                    entityID: allocation.entityID,
                    sortKey: maxSort + Self.sortKeyStep,
                    bookLocalPK: bookLocalPK,
                    collectionLocalPK: collectionLocalPK,
                    timestamp: timestamp,
                    assetID: assetID,
                    on: handle
                )
                try Self.touchCollection(localPK: collectionLocalPK, timestamp: timestamp, on: handle)
                return MembershipMutationResult(changed: true, assetID: assetID)
            },
            invariant: { handle, result in
                guard let assetID = result.assetID,
                      try Self.membershipCount(collectionLocalPK: collectionLocalPK, assetID: assetID, on: handle) > 0 else {
                    throw CollectionWriteError.writeFailed
                }
            },
            readBack: { connection, result in
                guard let handle = connection.handle,
                      let assetID = result.assetID,
                      try Self.membershipCount(collectionLocalPK: collectionLocalPK, assetID: assetID, on: handle) > 0 else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
        return result.changed
    }

    func removeBook(bookLocalPK: Int64, fromCollectionLocalPK collectionLocalPK: Int64) throws -> Bool {
        let result = try coordinator.perform(
            preflight: { connection in
                try Self.validateMembershipSchema(inserting: false, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.editableTarget(localPK: collectionLocalPK, scope: .membership, on: handle)
                _ = try Self.bookAssetID(localPK: bookLocalPK, on: handle)
            },
            revalidate: { handle in
                try Self.validateMembershipSchema(inserting: false, on: handle)
                let collectionEntity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: collectionLocalPK,
                    expectedEntityID: collectionEntity.entityID,
                    on: handle
                )
                _ = try Self.editableTarget(localPK: collectionLocalPK, scope: .membership, on: handle)
            },
            mutation: { handle in
                guard let assetID = try Self.bookAssetID(localPK: bookLocalPK, on: handle) else {
                    return MembershipMutationResult(changed: false, assetID: nil)
                }
                let memberEntity = try WriteSchemaGuard.entity(named: Self.memberEntityName, on: handle)
                try Self.validateMatchingMemberEntities(
                    collectionLocalPK: collectionLocalPK,
                    assetID: assetID,
                    expectedEntityID: memberEntity.entityID,
                    on: handle
                )
                let removed = try Self.removeMembershipRows(
                    collectionLocalPK: collectionLocalPK,
                    assetID: assetID,
                    on: handle
                )
                guard removed > 0 else {
                    return MembershipMutationResult(changed: false, assetID: assetID)
                }
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.touchCollection(localPK: collectionLocalPK, timestamp: timestamp, on: handle)
                return MembershipMutationResult(changed: true, assetID: assetID)
            },
            invariant: { handle, result in
                if let assetID = result.assetID {
                    guard try Self.membershipCount(collectionLocalPK: collectionLocalPK, assetID: assetID, on: handle) == 0 else {
                        throw CollectionWriteError.writeFailed
                    }
                }
            },
            readBack: { connection, result in
                if let assetID = result.assetID {
                    guard let handle = connection.handle,
                          try Self.membershipCount(collectionLocalPK: collectionLocalPK, assetID: assetID, on: handle) == 0 else {
                        throw CollectionWriteError.writeFailed
                    }
                }
            }
        )
        return result.changed
    }

    static func editableTarget(
        localPK: Int64,
        scope: CollectionWriteScope,
        on handle: OpaquePointer
    ) throws -> CollectionWriteTarget {
        var statement: OpaquePointer?
        let prepare = sqlite3_prepare_v2(
            handle,
            "SELECT Z_PK, ZCOLLECTIONID, ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK = ?",
            -1,
            &statement,
            nil
        )
        guard prepare == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CollectionWriteError.collectionMissing
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.collectionMissing
        }

        guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 2) == 0 else {
            throw CollectionWriteError.collectionDeletedOrUnknown
        }
        guard sqlite3_column_type(statement, 1) == SQLITE_TEXT,
              let rawID = sqlite3_column_text(statement, 1) else {
            throw CollectionWriteError.collectionIdentityUnavailable
        }
        let collectionID = String(cString: rawID)

        if scope == .membership, collectionID == membershipEditableSystemID {
            return CollectionWriteTarget(localPK: localPK)
        }
        guard UUID(uuidString: collectionID) != nil else {
            throw CollectionWriteError.collectionNotEditable
        }
        return CollectionWriteTarget(localPK: localPK)
    }

    private static func validateCreateSchema(on connection: SQLiteConnection) throws {
        try WriteSchemaGuard.validateTable(
            .collections,
            required: WriteSchemaGuard.collectionKnownColumns,
            inserting: true,
            on: connection
        )
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: connection)
    }

    private static func validateCreateSchema(on handle: OpaquePointer) throws {
        try WriteSchemaGuard.validateTable(
            .collections,
            required: WriteSchemaGuard.collectionKnownColumns,
            inserting: true,
            on: handle
        )
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: handle)
    }

    private static let renameColumns: Set<String> = [
        "Z_PK", "Z_ENT", "Z_OPT", "ZDELETEDFLAG", "ZCOLLECTIONID", "ZTITLE",
        "ZLASTMODIFICATION", "ZLOCALMODDATE",
    ]

    private static let deleteColumns: Set<String> = [
        "Z_PK", "Z_ENT", "Z_OPT", "ZDELETEDFLAG", "ZCOLLECTIONID",
        "ZLASTMODIFICATION", "ZLOCALMODDATE",
    ]

    private static let membershipCollectionColumns: Set<String> = [
        "Z_PK", "Z_ENT", "Z_OPT", "ZDELETEDFLAG", "ZCOLLECTIONID",
        "ZLASTMODIFICATION", "ZLOCALMODDATE",
    ]

    private static func validateRenameSchema(on connection: SQLiteConnection) throws {
        try WriteSchemaGuard.validateTable(.collections, required: renameColumns, inserting: false, on: connection)
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: connection)
    }

    private static func validateRenameSchema(on handle: OpaquePointer) throws {
        try WriteSchemaGuard.validateTable(.collections, required: renameColumns, inserting: false, on: handle)
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: handle)
    }

    private static func validateDeleteSchema(on connection: SQLiteConnection) throws {
        try WriteSchemaGuard.validateTable(.collections, required: deleteColumns, inserting: false, on: connection)
        try WriteSchemaGuard.validateTable(.members, required: ["ZCOLLECTION"], inserting: false, on: connection)
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: connection)
    }

    private static func validateDeleteSchema(on handle: OpaquePointer) throws {
        try WriteSchemaGuard.validateTable(.collections, required: deleteColumns, inserting: false, on: handle)
        try WriteSchemaGuard.validateTable(.members, required: ["ZCOLLECTION"], inserting: false, on: handle)
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: handle)
    }

    private static func validateMembershipSchema(inserting: Bool, on connection: SQLiteConnection) throws {
        try WriteSchemaGuard.validateTable(
            .collections,
            required: membershipCollectionColumns,
            inserting: false,
            on: connection
        )
        try WriteSchemaGuard.validateTable(
            .books,
            required: ["Z_PK", "ZASSETID"],
            inserting: false,
            on: connection
        )
        try WriteSchemaGuard.validateTable(
            .members,
            required: inserting ? WriteSchemaGuard.memberKnownColumns : ["Z_ENT", "ZCOLLECTION", "ZASSETID"],
            inserting: inserting,
            on: connection
        )
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: connection)
        _ = try WriteSchemaGuard.entity(named: memberEntityName, on: connection)
    }

    private static func validateMembershipSchema(inserting: Bool, on handle: OpaquePointer) throws {
        try WriteSchemaGuard.validateTable(
            .collections,
            required: membershipCollectionColumns,
            inserting: false,
            on: handle
        )
        try WriteSchemaGuard.validateTable(
            .books,
            required: ["Z_PK", "ZASSETID"],
            inserting: false,
            on: handle
        )
        try WriteSchemaGuard.validateTable(
            .members,
            required: inserting ? WriteSchemaGuard.memberKnownColumns : ["Z_ENT", "ZCOLLECTION", "ZASSETID"],
            inserting: inserting,
            on: handle
        )
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: handle)
        _ = try WriteSchemaGuard.entity(named: memberEntityName, on: handle)
    }

    private static func maximumPositiveSortKey(on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT MAX(ZSORTKEY) FROM ZBKCOLLECTION WHERE ZSORTKEY > 0",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CollectionWriteError.writeFailed }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return 0 }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw CollectionWriteError.writeFailed }
        return sqlite3_column_int64(statement, 0)
    }

    private static func insertCollection(
        localPK: Int64,
        entityID: Int64,
        sortKey: Int64,
        timestamp: Double,
        collectionID: String,
        details: String?,
        title: String,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO ZBKCOLLECTION
        (Z_PK,Z_ENT,Z_OPT,ZDELETEDFLAG,ZHIDDEN,ZPLACEHOLDER,ZSORTKEY,ZSORTMODE,ZVIEWMODE,
         ZLASTMODIFICATION,ZLOCALMODDATE,ZCOLLECTIONID,ZDETAILS,ZTITLE)
        VALUES(?,?,1,0,0,0,?,?,NULL,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, entityID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, sortKey) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, defaultSortMode) == SQLITE_OK,
              sqlite3_bind_double(statement, 5, timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 6, timestamp) == SQLITE_OK,
              bind(collectionID, to: statement, index: 7) == SQLITE_OK,
              bindOptional(details, to: statement, index: 8) == SQLITE_OK,
              bind(title, to: statement, index: 9) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func bookAssetID(localPK: Int64, on handle: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT ZASSETID FROM ZBKLIBRARYASSET WHERE Z_PK=?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK else {
            throw CollectionWriteError.writeFailed
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CollectionWriteError.bookMissing }
        guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
        guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, 0) else {
            throw CollectionWriteError.writeFailed
        }
        return String(cString: text)
    }

    private static func validateMatchingMemberEntities(
        collectionLocalPK: Int64,
        assetID: String,
        expectedEntityID: Int64,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT Z_ENT FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=? AND ZASSETID=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              bind(assetID, to: statement, index: 2) == SQLITE_OK else {
            throw CollectionWriteError.writeFailed
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 0) == expectedEntityID else {
                    throw WriteSchemaGuardError.entityMismatch(WriteSchemaTable.members.rawValue)
                }
            case SQLITE_DONE:
                return
            default:
                throw CollectionWriteError.writeFailed
            }
        }
    }

    private static func maximumMemberSortKey(collectionLocalPK: Int64, on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT MAX(ZSORTKEY) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.writeFailed
        }
        if sqlite3_column_type(statement, 0) == SQLITE_NULL { return 0 }
        guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER else { throw CollectionWriteError.writeFailed }
        return sqlite3_column_int64(statement, 0)
    }

    private static func insertMember(
        localPK: Int64,
        entityID: Int64,
        sortKey: Int64,
        bookLocalPK: Int64,
        collectionLocalPK: Int64,
        timestamp: Double,
        assetID: String,
        on handle: OpaquePointer
    ) throws {
        var statement: OpaquePointer?
        let sql = """
        INSERT INTO ZBKCOLLECTIONMEMBER
        (Z_PK,Z_ENT,Z_OPT,ZSORTKEY,ZASSET,ZCOLLECTION,ZLOCALMODDATE,ZASSETID,ZTEMPORARYASSETID)
        VALUES(?,?,1,?,?,?,?,?,NULL)
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, entityID) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, sortKey) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, bookLocalPK) == SQLITE_OK,
              sqlite3_bind_int64(statement, 5, collectionLocalPK) == SQLITE_OK,
              sqlite3_bind_double(statement, 6, timestamp) == SQLITE_OK,
              bind(assetID, to: statement, index: 7) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func touchCollection(localPK: Int64, timestamp: Double, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "UPDATE ZBKCOLLECTION SET Z_OPT=Z_OPT+1,ZLASTMODIFICATION=?,ZLOCALMODDATE=? WHERE Z_PK=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, timestamp) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func removeMembershipRows(collectionLocalPK: Int64, assetID: String, on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "DELETE FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=? AND ZASSETID=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              bind(assetID, to: statement, index: 2) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionWriteError.writeFailed
        }
        return Int64(sqlite3_changes(handle))
    }

    private static func membershipCount(collectionLocalPK: Int64, assetID: String, on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=? AND ZASSETID=?",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              bind(assetID, to: statement, index: 2) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.writeFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func tombstoneCollection(localPK: Int64, timestamp: Double, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = """
        UPDATE ZBKCOLLECTION
        SET ZDELETEDFLAG=1, Z_OPT=Z_OPT+1, ZLASTMODIFICATION=?, ZLOCALMODDATE=?
        WHERE Z_PK=?
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, timestamp) == SQLITE_OK,
              sqlite3_bind_int64(statement, 3, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func deleteMembershipRows(collectionLocalPK: Int64, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "DELETE FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func membershipCount(collectionLocalPK: Int64, on handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM ZBKCOLLECTIONMEMBER WHERE ZCOLLECTION=?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, collectionLocalPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.writeFailed
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func isDeleted(localPK: Int64, on handle: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT ZDELETEDFLAG FROM ZBKCOLLECTION WHERE Z_PK=?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
            throw CollectionWriteError.writeFailed
        }
        return sqlite3_column_int64(statement, 0) == 1
    }

    private static func updateTitle(localPK: Int64, title: String, timestamp: Double, on handle: OpaquePointer) throws {
        var statement: OpaquePointer?
        let sql = """
        UPDATE ZBKCOLLECTION
        SET ZTITLE=?, Z_OPT=Z_OPT+1, ZLASTMODIFICATION=?, ZLOCALMODDATE=?
        WHERE Z_PK=?
        """
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard bind(title, to: statement, index: 1) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, timestamp) == SQLITE_OK,
              sqlite3_bind_int64(statement, 4, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE,
              sqlite3_changes(handle) == 1 else {
            throw CollectionWriteError.writeFailed
        }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, index: Int32) -> Int32 {
        value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func bindOptional(_ value: String?, to statement: OpaquePointer, index: Int32) -> Int32 {
        guard let value else { return sqlite3_bind_null(statement, index) }
        return bind(value, to: statement, index: index)
    }

    private struct CreatedCollection {
        let localPK: Int64
        let entityID: Int64
        let title: String
    }

    private struct MembershipMutationResult {
        let changed: Bool
        let assetID: String?
    }
}

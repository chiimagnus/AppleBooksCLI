import Foundation
import SQLite3

public enum CollectionWriteError: Error, Equatable, Sendable {
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
    let stableID: String?
}

private enum CollectionWriteSelector {
    case localPK(Int64)
    case collectionID(String)
}

private enum BookWriteSelector {
    case localPK(Int64)
    case assetID(String)
}

private struct BookWriteTarget: Equatable {
    let localPK: Int64
    let assetID: String?
}

struct CollectionWriter {
    private static let collectionEntityName = "BKCollection"
    private static let memberEntityName = "BKCollectionMember"
    private static let sortKeyStep: Int64 = 10_000
    private static let defaultSortMode: Int64 = 6

    private let coordinator: MutationCoordinator
    private let cloudProjector: CollectionCloudProjector?
    private let cloudSynchronizer: CollectionCloudSynchronizer?

    init(
        database: URL,
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        keep: Int = SQLiteBackup.retentionCount,
        booksApp: BooksAppController = .live,
        cloudProjector: CollectionCloudProjector? = nil,
        cloudSynchronizer: CollectionCloudSynchronizer? = nil
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

    func createCollection(title: String, details: String? = nil, syncCloud: Bool = false) throws -> MutationResult {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else { throw CollectionWriteError.invalidTitle }

        let cloudProjection: ((CreatedCollection) throws -> Void)? = cloudProjector.map { projector in
            { created in
                try projector.project(.collection(localPK: created.localPK))
            }
        }

        return try coordinator.perform(
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
                    collectionID: collectionID,
                    title: normalizedTitle,
                    sortKey: sortKey,
                    timestamp: timestamp
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
            domainData: {
                MutationDomainData(localPK: $0.localPK, stableID: $0.collectionID, changed: true)
            },
            cloudProjection: cloudProjection,
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { created, onTemporaryBooksLaunch in
                    try synchronizer.syncCollection(
                        localPK: created.localPK,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, created in
                guard let collection = try Self.readBackCollection(localPK: created.localPK, on: connection),
                      collection.collectionID == created.collectionID,
                      collection.title == created.title else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
    }

    func renameCollection(localPK: Int64, newTitle: String, syncCloud: Bool = false) throws -> MutationResult {
        try renameCollection(.localPK(localPK), newTitle: newTitle, syncCloud: syncCloud)
    }

    func renameCollection(collectionID: String, newTitle: String, syncCloud: Bool = false) throws -> MutationResult {
        try renameCollection(.collectionID(collectionID), newTitle: newTitle, syncCloud: syncCloud)
    }

    func deleteCollection(localPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try deleteCollection(.localPK(localPK), syncCloud: syncCloud)
    }

    func deleteCollection(collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try deleteCollection(.collectionID(collectionID), syncCloud: syncCloud)
    }

    func addBook(bookLocalPK: Int64, toCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try addBook(.localPK(bookLocalPK), to: .localPK(collectionLocalPK), syncCloud: syncCloud)
    }

    func addBook(assetID: String, toCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try addBook(.assetID(assetID), to: .collectionID(collectionID), syncCloud: syncCloud)
    }

    func addBook(bookLocalPK: Int64, toCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try addBook(.localPK(bookLocalPK), to: .collectionID(collectionID), syncCloud: syncCloud)
    }

    func addBook(assetID: String, toCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try addBook(.assetID(assetID), to: .localPK(collectionLocalPK), syncCloud: syncCloud)
    }

    func removeBook(bookLocalPK: Int64, fromCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try removeBook(.localPK(bookLocalPK), from: .localPK(collectionLocalPK), syncCloud: syncCloud)
    }

    func removeBook(assetID: String, fromCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try removeBook(.assetID(assetID), from: .collectionID(collectionID), syncCloud: syncCloud)
    }

    func removeBook(bookLocalPK: Int64, fromCollectionID collectionID: String, syncCloud: Bool = false) throws -> MutationResult {
        try removeBook(.localPK(bookLocalPK), from: .collectionID(collectionID), syncCloud: syncCloud)
    }

    func removeBook(assetID: String, fromCollectionLocalPK collectionLocalPK: Int64, syncCloud: Bool = false) throws -> MutationResult {
        try removeBook(.assetID(assetID), from: .localPK(collectionLocalPK), syncCloud: syncCloud)
    }

    private func renameCollection(_ selector: CollectionWriteSelector, newTitle: String, syncCloud: Bool) throws -> MutationResult {
        let normalizedTitle = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTitle.isEmpty == false else { throw CollectionWriteError.invalidTitle }

        return try coordinator.perform(
            preflight: { connection in
                try Self.validateRenameSchema(on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.resolveCollection(selector, scope: .collection, on: handle)
            },
            quietDecision: { connection in
                try Self.validateRenameSchema(on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                let target = try Self.resolveCollection(selector, scope: .collection, on: handle)
                guard try Self.currentTitle(localPK: target.localPK, on: handle) == normalizedTitle else {
                    return .needsMutation
                }
                return .noChange(MutationDomainData(localPK: target.localPK, stableID: target.stableID, changed: false))
            },
            revalidate: { handle in
                try Self.validateRenameSchema(on: handle)
                let target = try Self.resolveCollection(selector, scope: .collection, on: handle)
                let entity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: target.localPK,
                    expectedEntityID: entity.entityID,
                    on: handle
                )
            },
            mutation: { handle in
                let target = try Self.resolveCollection(selector, scope: .collection, on: handle)
                if try Self.currentTitle(localPK: target.localPK, on: handle) == normalizedTitle {
                    return RenameMutationResult(changed: false, target: target)
                }
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.updateTitle(localPK: target.localPK, title: normalizedTitle, timestamp: timestamp, on: handle)
                return RenameMutationResult(changed: true, target: target)
            },
            invariant: { handle, payload in
                _ = try Self.editableTarget(localPK: payload.target.localPK, scope: .collection, on: handle)
            },
            domainData: { payload in
                MutationDomainData(
                    localPK: payload.target.localPK,
                    stableID: payload.target.stableID,
                    changed: payload.changed
                )
            },
            cloudProjection: cloudProjector.map { projector in
                { payload in try projector.project(.collection(localPK: payload.target.localPK)) }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { payload, onTemporaryBooksLaunch in
                    try synchronizer.syncCollection(
                        localPK: payload.target.localPK,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, payload in
                guard let collection = try Self.readBackCollection(localPK: payload.target.localPK, on: connection),
                      collection.title == normalizedTitle else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
    }

    private func deleteCollection(_ selector: CollectionWriteSelector, syncCloud: Bool) throws -> MutationResult {
        return try coordinator.perform(
            preflight: { connection in
                try Self.validateDeleteSchema(on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.resolveCollection(selector, scope: .collection, on: handle)
            },
            revalidate: { handle in
                try Self.validateDeleteSchema(on: handle)
                let target = try Self.resolveCollection(selector, scope: .collection, on: handle)
                let entity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: target.localPK,
                    expectedEntityID: entity.entityID,
                    on: handle
                )
            },
            mutation: { handle in
                let target = try Self.resolveCollection(selector, scope: .collection, on: handle)
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.tombstoneCollection(localPK: target.localPK, timestamp: timestamp, on: handle)
                try Self.deleteMembershipRows(collectionLocalPK: target.localPK, on: handle)
                return target
            },
            invariant: { handle, target in
                guard try Self.isDeleted(localPK: target.localPK, on: handle),
                      try Self.membershipCount(collectionLocalPK: target.localPK, on: handle) == 0 else {
                    throw CollectionWriteError.writeFailed
                }
            },
            domainData: {
                MutationDomainData(localPK: $0.localPK, stableID: $0.stableID, changed: true)
            },
            cloudProjection: cloudProjector.map { projector in
                { target in try projector.project(.collection(localPK: target.localPK)) }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { target, onTemporaryBooksLaunch in
                    try synchronizer.syncCollection(
                        localPK: target.localPK,
                        deleting: true,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, target in
                guard let handle = connection.handle,
                      try Self.isDeleted(localPK: target.localPK, on: handle),
                      try Self.membershipCount(collectionLocalPK: target.localPK, on: handle) == 0 else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
    }

    private func addBook(_ bookSelector: BookWriteSelector, to collectionSelector: CollectionWriteSelector, syncCloud: Bool) throws -> MutationResult {
        return try coordinator.perform(
            preflight: { connection in
                try Self.validateMembershipSchema(inserting: true, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                _ = try Self.resolveBook(bookSelector, requireAssetID: true, on: handle)
            },
            quietDecision: { connection in
                try Self.validateMembershipSchema(inserting: true, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                let book = try Self.resolveBook(bookSelector, requireAssetID: true, on: handle)
                guard let assetID = book.assetID else { throw CollectionWriteError.bookAssetIDUnavailable }
                guard try Self.membershipCount(collectionLocalPK: collection.localPK, assetID: assetID, on: handle) > 0 else {
                    return .needsMutation
                }
                let memberEntity = try WriteSchemaGuard.entity(named: Self.memberEntityName, on: handle)
                do {
                    try Self.validateMatchingMemberEntities(
                        collectionLocalPK: collection.localPK,
                        assetID: assetID,
                        expectedEntityID: memberEntity.entityID,
                        on: handle
                    )
                } catch {
                    return .needsMutation
                }
                return .noChange(Self.membershipDomainData(
                    collection: collection,
                    bookLocalPK: book.localPK,
                    assetID: assetID,
                    changed: false
                ))
            },
            revalidate: { handle in
                try Self.validateMembershipSchema(inserting: true, on: handle)
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                _ = try Self.resolveBook(bookSelector, requireAssetID: true, on: handle)
                let collectionEntity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: collection.localPK,
                    expectedEntityID: collectionEntity.entityID,
                    on: handle
                )
            },
            mutation: { handle in
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                let book = try Self.resolveBook(bookSelector, requireAssetID: true, on: handle)
                guard let assetID = book.assetID else { throw CollectionWriteError.bookAssetIDUnavailable }
                let memberEntity = try WriteSchemaGuard.entity(named: Self.memberEntityName, on: handle)
                try Self.validateMatchingMemberEntities(
                    collectionLocalPK: collection.localPK,
                    assetID: assetID,
                    expectedEntityID: memberEntity.entityID,
                    on: handle
                )
                if try Self.membershipCount(collectionLocalPK: collection.localPK, assetID: assetID, on: handle) > 0 {
                    return MembershipMutationResult(changed: false, bookLocalPK: book.localPK, assetID: assetID, collection: collection)
                }

                let allocation = try CoreDataPrimaryKey.allocate(
                    entityName: Self.memberEntityName,
                    table: .members,
                    on: handle
                )
                let maxSort = try Self.maximumMemberSortKey(collectionLocalPK: collection.localPK, on: handle)
                guard maxSort <= Int64.max - Self.sortKeyStep else { throw CollectionWriteError.writeFailed }
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.insertMember(
                    localPK: allocation.localPK,
                    entityID: allocation.entityID,
                    sortKey: maxSort + Self.sortKeyStep,
                    bookLocalPK: book.localPK,
                    collectionLocalPK: collection.localPK,
                    timestamp: timestamp,
                    assetID: assetID,
                    on: handle
                )
                try Self.touchCollection(localPK: collection.localPK, timestamp: timestamp, on: handle)
                return MembershipMutationResult(changed: true, bookLocalPK: book.localPK, assetID: assetID, collection: collection)
            },
            invariant: { handle, result in
                guard let assetID = result.assetID,
                      try Self.membershipCount(
                        collectionLocalPK: result.collection.localPK,
                        assetID: assetID,
                        on: handle
                      ) > 0 else {
                    throw CollectionWriteError.writeFailed
                }
            },
            domainData: {
                Self.membershipDomainData(
                    collection: $0.collection,
                    bookLocalPK: $0.bookLocalPK,
                    assetID: $0.assetID,
                    changed: $0.changed
                )
            },
            cloudProjection: cloudProjector.map { projector in
                { mutation in
                    var inputs: [CollectionCloudProjectionInput] = [.collection(localPK: mutation.collection.localPK)]
                    if let assetID = mutation.assetID {
                        inputs.append(.member(collectionLocalPK: mutation.collection.localPK, assetID: assetID))
                    }
                    try projector.project(inputs)
                }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { mutation, onTemporaryBooksLaunch in
                    guard let assetID = mutation.assetID else { throw CollectionCloudSyncError.cloudRecordMissing }
                    try synchronizer.syncMembership(
                        collectionLocalPK: mutation.collection.localPK,
                        assetID: assetID,
                        deleting: false,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, result in
                guard let handle = connection.handle,
                      let assetID = result.assetID,
                      try Self.membershipCount(
                        collectionLocalPK: result.collection.localPK,
                        assetID: assetID,
                        on: handle
                      ) > 0 else {
                    throw CollectionWriteError.writeFailed
                }
            }
        )
    }

    private func removeBook(_ bookSelector: BookWriteSelector, from collectionSelector: CollectionWriteSelector, syncCloud: Bool) throws -> MutationResult {
        return try coordinator.perform(
            preflight: { connection in
                try Self.validateMembershipSchema(inserting: false, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                _ = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                _ = try Self.resolveBook(bookSelector, requireAssetID: false, on: handle)
            },
            quietDecision: { connection in
                try Self.validateMembershipSchema(inserting: false, on: connection)
                guard let handle = connection.handle else { throw CollectionWriteError.collectionMissing }
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                let book = try Self.resolveBook(bookSelector, requireAssetID: false, on: handle)
                guard let assetID = book.assetID else {
                    return .noChange(Self.membershipDomainData(
                        collection: collection,
                        bookLocalPK: book.localPK,
                        assetID: nil,
                        changed: false
                    ))
                }
                guard try Self.membershipCount(collectionLocalPK: collection.localPK, assetID: assetID, on: handle) == 0 else {
                    return .needsMutation
                }
                return .noChange(Self.membershipDomainData(
                    collection: collection,
                    bookLocalPK: book.localPK,
                    assetID: assetID,
                    changed: false
                ))
            },
            revalidate: { handle in
                try Self.validateMembershipSchema(inserting: false, on: handle)
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                _ = try Self.resolveBook(bookSelector, requireAssetID: false, on: handle)
                let collectionEntity = try WriteSchemaGuard.entity(named: Self.collectionEntityName, on: handle)
                try WriteSchemaGuard.validateExistingEntity(
                    table: .collections,
                    localPK: collection.localPK,
                    expectedEntityID: collectionEntity.entityID,
                    on: handle
                )
            },
            mutation: { handle in
                let collection = try Self.resolveCollection(collectionSelector, scope: .membership, on: handle)
                let book = try Self.resolveBook(bookSelector, requireAssetID: false, on: handle)
                guard let assetID = book.assetID else {
                    return MembershipMutationResult(changed: false, bookLocalPK: book.localPK, assetID: nil, collection: collection)
                }
                let memberEntity = try WriteSchemaGuard.entity(named: Self.memberEntityName, on: handle)
                try Self.validateMatchingMemberEntities(
                    collectionLocalPK: collection.localPK,
                    assetID: assetID,
                    expectedEntityID: memberEntity.entityID,
                    on: handle
                )
                let removed = try Self.removeMembershipRows(
                    collectionLocalPK: collection.localPK,
                    assetID: assetID,
                    on: handle
                )
                guard removed > 0 else {
                    return MembershipMutationResult(changed: false, bookLocalPK: book.localPK, assetID: assetID, collection: collection)
                }
                let timestamp = CoreDataTime.seconds(from: Date())!
                try Self.touchCollection(localPK: collection.localPK, timestamp: timestamp, on: handle)
                return MembershipMutationResult(changed: true, bookLocalPK: book.localPK, assetID: assetID, collection: collection)
            },
            invariant: { handle, result in
                if let assetID = result.assetID {
                    guard try Self.membershipCount(
                        collectionLocalPK: result.collection.localPK,
                        assetID: assetID,
                        on: handle
                    ) == 0 else {
                        throw CollectionWriteError.writeFailed
                    }
                }
            },
            domainData: {
                Self.membershipDomainData(
                    collection: $0.collection,
                    bookLocalPK: $0.bookLocalPK,
                    assetID: $0.assetID,
                    changed: $0.changed
                )
            },
            cloudProjection: cloudProjector.map { projector in
                { mutation in
                    var inputs: [CollectionCloudProjectionInput] = [.collection(localPK: mutation.collection.localPK)]
                    if let assetID = mutation.assetID {
                        inputs.append(.member(collectionLocalPK: mutation.collection.localPK, assetID: assetID))
                    }
                    try projector.project(inputs)
                }
            },
            acknowledgementRequested: syncCloud,
            acknowledgement: cloudSynchronizer.map { synchronizer in
                { mutation, onTemporaryBooksLaunch in
                    guard let assetID = mutation.assetID else { throw CollectionCloudSyncError.cloudRecordMissing }
                    try synchronizer.syncMembership(
                        collectionLocalPK: mutation.collection.localPK,
                        assetID: assetID,
                        deleting: true,
                        onTemporaryBooksLaunch: onTemporaryBooksLaunch
                    )
                }
            },
            readBack: { connection, result in
                if let assetID = result.assetID {
                    guard let handle = connection.handle,
                          try Self.membershipCount(
                            collectionLocalPK: result.collection.localPK,
                            assetID: assetID,
                            on: handle
                          ) == 0 else {
                        throw CollectionWriteError.writeFailed
                    }
                }
            }
        )
    }

    private static func readBackCollection(
        localPK: Int64,
        on connection: SQLiteConnection
    ) throws -> (collectionID: String?, title: String?)? {
        let statement = try connection.prepare("""
            SELECT ZCOLLECTIONID, ZTITLE
            FROM ZBKCOLLECTION
            WHERE Z_PK = ? AND ZDELETEDFLAG = 0
            LIMIT 2
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { return nil }
        let row = try SQLiteRow(statement: statement)
        let result = (
            collectionID: try row.text("ZCOLLECTIONID"),
            title: try row.text("ZTITLE")
        )
        guard try statement.step() == false else { throw CollectionWriteError.writeFailed }
        return result
    }

    private static func resolveCollection(
        _ selector: CollectionWriteSelector,
        scope: CollectionWriteScope,
        on handle: OpaquePointer
    ) throws -> CollectionWriteTarget {
        switch selector {
        case let .localPK(localPK):
            return try editableTarget(localPK: localPK, scope: scope, on: handle)
        case let .collectionID(collectionID):
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT Z_PK,ZCOLLECTIONID FROM ZBKCOLLECTION WHERE ZCOLLECTIONID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement else {
                throw CollectionWriteError.collectionMissing
            }
            defer { sqlite3_finalize(statement) }
            guard bind(collectionID, to: statement, index: 1) == SQLITE_OK else {
                throw CollectionWriteError.writeFailed
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CollectionWriteError.collectionMissing }
            guard sqlite3_column_type(statement, 1) == SQLITE_TEXT else {
                throw CollectionWriteError.collectionIdentityUnavailable
            }
            let storedID: String
            do {
                storedID = try decodeSQLiteText(statement, at: 1)
            } catch {
                throw CollectionWriteError.collectionIdentityUnavailable
            }
            guard storedID == collectionID else {
                throw CollectionWriteError.collectionIdentityUnavailable
            }
            let localPK = sqlite3_column_int64(statement, 0)
            let second = sqlite3_step(statement)
            if second == SQLITE_ROW { throw StableIdentityError.ambiguousCollectionID }
            guard second == SQLITE_DONE else { throw CollectionWriteError.writeFailed }
            _ = try editableTarget(localPK: localPK, scope: scope, on: handle)
            return CollectionWriteTarget(localPK: localPK, stableID: collectionID)
        }
    }

    private static func resolveBook(
        _ selector: BookWriteSelector,
        requireAssetID: Bool,
        on handle: OpaquePointer
    ) throws -> BookWriteTarget {
        switch selector {
        case let .localPK(localPK):
            let assetID = try bookAssetID(localPK: localPK, on: handle)
            if requireAssetID, assetID == nil { throw CollectionWriteError.bookAssetIDUnavailable }
            return BookWriteTarget(localPK: localPK, assetID: assetID)
        case let .assetID(assetID):
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                handle,
                "SELECT Z_PK,ZASSETID FROM ZBKLIBRARYASSET WHERE ZASSETID=? COLLATE BINARY ORDER BY Z_PK LIMIT 2",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement else {
                throw CollectionWriteError.bookMissing
            }
            defer { sqlite3_finalize(statement) }
            guard bind(assetID, to: statement, index: 1) == SQLITE_OK else {
                throw CollectionWriteError.writeFailed
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw CollectionWriteError.bookMissing }
            guard sqlite3_column_type(statement, 1) == SQLITE_TEXT else {
                throw CollectionWriteError.bookAssetIDUnavailable
            }
            let storedID: String
            do {
                storedID = try decodeSQLiteText(statement, at: 1)
            } catch {
                throw CollectionWriteError.bookAssetIDUnavailable
            }
            guard storedID == assetID else {
                throw CollectionWriteError.bookAssetIDUnavailable
            }
            let localPK = sqlite3_column_int64(statement, 0)
            let second = sqlite3_step(statement)
            if second == SQLITE_ROW { throw StableIdentityError.ambiguousBookAssetID }
            guard second == SQLITE_DONE else { throw CollectionWriteError.writeFailed }
            return BookWriteTarget(localPK: localPK, assetID: assetID)
        }
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
        guard sqlite3_column_type(statement, 1) == SQLITE_TEXT else {
            throw CollectionWriteError.collectionIdentityUnavailable
        }
        let collectionID: String
        do {
            collectionID = try decodeSQLiteText(statement, at: 1)
        } catch {
            throw CollectionWriteError.collectionIdentityUnavailable
        }

        let capabilities = CollectionIdentityEditPolicy.capabilities(for: collectionID)
        let isEditable = switch scope {
        case .collection: capabilities.canEditCollection
        case .membership: capabilities.canEditMembership
        }
        guard isEditable else { throw CollectionWriteError.collectionNotEditable }
        return CollectionWriteTarget(localPK: localPK, stableID: collectionID)
    }

    static func validateWriteReadiness(on connection: SQLiteConnection) throws {
        try validateCreateSchema(on: connection)
        try validateMembershipSchema(inserting: true, on: connection)
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
    }

    private static func validateDeleteSchema(on connection: SQLiteConnection) throws {
        try WriteSchemaGuard.validateTable(.collections, required: deleteColumns, inserting: false, on: connection)
        try WriteSchemaGuard.validateTable(.members, required: ["ZCOLLECTION"], inserting: false, on: connection)
        _ = try WriteSchemaGuard.entity(named: collectionEntityName, on: connection)
    }

    private static func validateDeleteSchema(on handle: OpaquePointer) throws {
        try WriteSchemaGuard.validateTable(.collections, required: deleteColumns, inserting: false, on: handle)
        try WriteSchemaGuard.validateTable(.members, required: ["ZCOLLECTION"], inserting: false, on: handle)
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
        guard sqlite3_column_type(statement, 0) == SQLITE_TEXT else {
            throw CollectionWriteError.writeFailed
        }
        do {
            return try decodeSQLiteText(statement, at: 0)
        } catch {
            throw CollectionWriteError.writeFailed
        }
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

    private static func currentTitle(localPK: Int64, on handle: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT ZTITLE FROM ZBKCOLLECTION WHERE Z_PK=? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CollectionWriteError.writeFailed
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_int64(statement, 1, localPK) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else {
            throw CollectionWriteError.writeFailed
        }
        let title: String?
        switch sqlite3_column_type(statement, 0) {
        case SQLITE_NULL:
            title = nil
        case SQLITE_TEXT:
            do {
                title = try decodeSQLiteText(statement, at: 0)
            } catch {
                throw CollectionWriteError.writeFailed
            }
        default:
            throw CollectionWriteError.writeFailed
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw CollectionWriteError.writeFailed }
        return title
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
        bindSQLiteText(value, to: statement, at: index)
    }

    private static func bindOptional(_ value: String?, to statement: OpaquePointer, index: Int32) -> Int32 {
        guard let value else { return sqlite3_bind_null(statement, index) }
        return bind(value, to: statement, index: index)
    }

    func pendingCloudChangeCount() throws -> Int {
        guard let cloudSynchronizer else { throw AppleBooksCloudSyncError.unavailable }
        return try cloudSynchronizer.pendingCount()
    }

    func syncPendingCloudChanges() throws {
        guard let cloudSynchronizer else { throw AppleBooksCloudSyncError.unavailable }
        try cloudSynchronizer.syncPending()
    }

    private struct CreatedCollection {
        let localPK: Int64
        let entityID: Int64
        let collectionID: String
        let title: String
        let sortKey: Int64
        let timestamp: Double
    }

    private static func membershipDomainData(
        collection: CollectionWriteTarget,
        bookLocalPK: Int64,
        assetID: String?,
        changed: Bool
    ) -> MutationDomainData {
        MutationDomainData(
            localPK: collection.localPK,
            stableID: collection.stableID,
            relatedLocalPK: bookLocalPK,
            relatedStableID: assetID,
            changed: changed
        )
    }

    private struct RenameMutationResult {
        let changed: Bool
        let target: CollectionWriteTarget
    }

    private struct MembershipMutationResult {
        let changed: Bool
        let bookLocalPK: Int64
        let assetID: String?
        let collection: CollectionWriteTarget
    }
}

import AppleBooksCloudBridge
import Foundation

enum CollectionCloudProjectionInput: Equatable {
    case collection(localPK: Int64)
    case member(collectionLocalPK: Int64, assetID: String)
}

enum CollectionCloudProjectionError: Error, Equatable {
    case collectionIdentityUnavailable
    case bridgeRejected(Int32)
}

struct CollectionCloudProjector {
    typealias BackupAction = (URL, URL) throws -> Void
    typealias BridgeAction = (URL, URL, URL, CollectionCloudProjectionInput) -> Int32

    private let projectAction: ([CollectionCloudProjectionInput]) throws -> Void

    init(projectAction: @escaping ([CollectionCloudProjectionInput]) throws -> Void) {
        self.projectAction = projectAction
    }

    func project(_ input: CollectionCloudProjectionInput) throws {
        try projectAction([input])
    }

    func project(_ inputs: [CollectionCloudProjectionInput]) throws {
        try projectAction(inputs)
    }

    static func live(
        libraryDatabase: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        backupRoot: URL = SQLiteBackup.defaultRoot().appendingPathComponent("cloud", isDirectory: true),
        backupAction: @escaping BackupAction = { source, root in
            _ = try SQLiteBackup.create(source: source, backupRoot: root)
        },
        bridgeAction: @escaping BridgeAction = liveBridgeAction
    ) -> CollectionCloudProjector? {
        guard let location = CollectionCloudStoreLocation.live(
            libraryDatabase: libraryDatabase,
            homeDirectory: homeDirectory
        ) else {
            return nil
        }

        return CollectionCloudProjector { inputs in
            try backupAction(location.database, backupRoot)
            for input in inputs {
                let status = bridgeAction(location.root, location.database, libraryDatabase, input)
                guard status == 0 else {
                    throw CollectionCloudProjectionError.bridgeRejected(status)
                }
            }
        }
    }

    private static func liveBridgeAction(
        root: URL,
        database: URL,
        libraryDatabase: URL,
        input: CollectionCloudProjectionInput
    ) -> Int32 {
        let collectionLocalPK: Int64
        switch input {
        case let .collection(localPK):
            collectionLocalPK = localPK
        case let .member(localPK, _):
            collectionLocalPK = localPK
        }
        guard let collectionID = try? collectionID(libraryDatabase: libraryDatabase, localPK: collectionLocalPK) else {
            return -1
        }

        return root.path.withCString { rootPath in
            database.path.withCString { databasePath in
                libraryDatabase.path.withCString { libraryPath in
                    withCloudBridgeUTF8Bytes(collectionID) { collectionIDBytes, collectionIDLength in
                        switch input {
                        case .collection:
                            ABProjectCollectionState(
                                rootPath,
                                databasePath,
                                libraryPath,
                                collectionIDBytes,
                                collectionIDLength
                            )
                        case let .member(_, assetID):
                            withCloudBridgeUTF8Bytes(assetID) { assetIDBytes, assetIDLength in
                                ABProjectCollectionMemberState(
                                    rootPath,
                                    databasePath,
                                    libraryPath,
                                    collectionIDBytes,
                                    collectionIDLength,
                                    assetIDBytes,
                                    assetIDLength
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    static func collectionID(libraryDatabase: URL, localPK: Int64) throws -> String {
        let connection = try SQLiteConnection.readOnly(path: libraryDatabase.path)
        defer { try? connection.close() }
        let projection = SQLiteTextProjection.exact(
            "ZCOLLECTIONID",
            alias: "cloudCollectionID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        )
        let statement = try connection.prepare("""
            SELECT \(projection.joined(separator: ", "))
            FROM ZBKCOLLECTION
            WHERE Z_PK=?
            ORDER BY rowid
            LIMIT 2
            """)
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { throw CollectionCloudProjectionError.collectionIdentityUnavailable }
        let row = try SQLiteRow(statement: statement)
        let collectionID: String
        switch try SQLiteTextProjection.decodeExact(
            row,
            alias: "cloudCollectionID",
            column: "ZCOLLECTIONID",
            maximumUTF8Bytes: CloudProjectionResourcePolicy.stableIdentityBytes
        ) {
        case let .value(value) where value.isEmpty == false: collectionID = value
        case .value, .null, .oversized: throw CollectionCloudProjectionError.collectionIdentityUnavailable
        }
        guard try statement.step() == false else {
            throw CollectionCloudProjectionError.collectionIdentityUnavailable
        }
        return collectionID
    }
}

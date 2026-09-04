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
        guard inputs.isEmpty == false else { return }
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
                    collectionID.withCString { collectionIDPath in
                        switch input {
                        case .collection:
                            ABProjectCollectionState(rootPath, databasePath, libraryPath, collectionIDPath)
                        case let .member(_, assetID):
                            assetID.withCString { assetIDPath in
                                ABProjectCollectionMemberState(rootPath, databasePath, libraryPath, collectionIDPath, assetIDPath)
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
        let statement = try connection.prepare("SELECT ZCOLLECTIONID FROM ZBKCOLLECTION WHERE Z_PK=? ORDER BY rowid")
        try statement.bind(localPK, at: 1)
        guard try statement.step() else { throw CollectionCloudProjectionError.collectionIdentityUnavailable }
        let row = try SQLiteRow(statement: statement)
        guard let collectionID = try row.text("ZCOLLECTIONID"), collectionID.isEmpty == false,
              try statement.step() == false else {
            throw CollectionCloudProjectionError.collectionIdentityUnavailable
        }
        return collectionID
    }
}

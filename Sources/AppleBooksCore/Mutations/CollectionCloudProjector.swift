import AppleBooksCloudBridge
import Foundation

struct CollectionCloudProjectionInput: Equatable {
    let collectionID: String
    let title: String
    let sortOrder: Int64
    let modificationDateReferenceSeconds: Double
}

enum CollectionCloudProjectionError: Error, Equatable {
    case bridgeRejected(Int32)
}

struct CollectionCloudProjector {
    typealias BackupAction = (URL, URL) throws -> Void
    typealias BridgeAction = (URL, URL, CollectionCloudProjectionInput) -> Int32

    private let projectAction: (CollectionCloudProjectionInput) throws -> Void

    init(projectAction: @escaping (CollectionCloudProjectionInput) throws -> Void) {
        self.projectAction = projectAction
    }

    func project(_ input: CollectionCloudProjectionInput) throws {
        try projectAction(input)
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

        return CollectionCloudProjector { input in
            try backupAction(location.database, backupRoot)
            let status = bridgeAction(location.root, location.database, input)
            guard status == 0 else {
                throw CollectionCloudProjectionError.bridgeRejected(status)
            }
        }
    }

    private static func liveBridgeAction(
        root: URL,
        database: URL,
        input: CollectionCloudProjectionInput
    ) -> Int32 {
        root.path.withCString { rootPath in
            database.path.withCString { databasePath in
                input.collectionID.withCString { collectionID in
                    input.title.withCString { title in
                        ABProjectCollectionDetail(
                            rootPath,
                            databasePath,
                            collectionID,
                            title,
                            input.sortOrder,
                            input.modificationDateReferenceSeconds
                        )
                    }
                }
            }
        }
    }
}

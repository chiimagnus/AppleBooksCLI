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
        let databasePaths = AppleBooksDatabasePaths.defaults(homeDirectory: homeDirectory)
        let discovery = DatabaseDiscovery(paths: databasePaths)
        guard case let .success(discoveredLibrary) = discovery.probe(store: .library),
              discoveredLibrary == libraryDatabase.standardizedFileURL.resolvingSymlinksInPath() else {
            return nil
        }

        // ponytail: 该私有布局只覆盖当前已验证的 macOS；路径变化时保持失败关闭，先在隔离 clone 验证后再升级。
        let root = homeDirectory
            .appendingPathComponent("Library/Group Containers/group.com.apple.iBooks/Documents/BCCloudData-BookDataStoreService", isDirectory: true)
        let cloudDatabase = root
            .appendingPathComponent("BCCloudCollections", isDirectory: true)
            .appendingPathComponent("BCCloudCollections", isDirectory: false)

        return CollectionCloudProjector { input in
            try backupAction(cloudDatabase, backupRoot)
            let status = bridgeAction(root, cloudDatabase, input)
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

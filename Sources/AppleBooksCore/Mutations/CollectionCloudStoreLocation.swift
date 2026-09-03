import Foundation

struct CollectionCloudStoreLocation: Equatable {
    let root: URL
    let database: URL

    static func live(
        libraryDatabase: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CollectionCloudStoreLocation? {
        let databasePaths = AppleBooksDatabasePaths.defaults(homeDirectory: homeDirectory)
        let discovery = DatabaseDiscovery(paths: databasePaths)
        guard case let .success(discoveredLibrary) = discovery.probe(store: .library),
              discoveredLibrary == libraryDatabase.standardizedFileURL.resolvingSymlinksInPath() else {
            return nil
        }

        // ponytail: 该私有布局只覆盖当前已验证的 macOS；路径变化时保持失败关闭，先在隔离 clone 验证后再升级。
        let root = homeDirectory
            .appendingPathComponent("Library/Group Containers/group.com.apple.iBooks/Documents/BCCloudData-BookDataStoreService", isDirectory: true)
        let database = root
            .appendingPathComponent("BCCloudCollections", isDirectory: true)
            .appendingPathComponent("BCCloudCollections", isDirectory: false)
        return CollectionCloudStoreLocation(root: root, database: database)
    }
}

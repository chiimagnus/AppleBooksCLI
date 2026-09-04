import Foundation

struct AnnotationCloudStoreLocation: Equatable {
    let root: URL
    let database: URL

    static func live(
        annotationsDatabase: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AnnotationCloudStoreLocation? {
        let discovery = DatabaseDiscovery(paths: .defaults(homeDirectory: homeDirectory))
        guard case let .success(discoveredAnnotations) = discovery.probe(store: .annotations),
              discoveredAnnotations == annotationsDatabase.standardizedFileURL.resolvingSymlinksInPath() else {
            return nil
        }

        // ponytail: 该 Books client-side private store 布局只覆盖当前已验证的 macOS；路径变化时保持失败关闭。
        let root = homeDirectory
            .appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents/BCCloudData-iBooks", isDirectory: true)
        let database = root
            .appendingPathComponent("BCAssetData", isDirectory: true)
            .appendingPathComponent("BCAssetData", isDirectory: false)
        return AnnotationCloudStoreLocation(root: root, database: database)
    }
}

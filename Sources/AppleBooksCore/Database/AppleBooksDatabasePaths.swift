import Foundation

public struct AppleBooksDatabasePaths: Equatable, Sendable {
    public let libraryDirectory: URL
    public let annotationsDirectory: URL

    public init(libraryDirectory: URL, annotationsDirectory: URL) {
        self.libraryDirectory = libraryDirectory
        self.annotationsDirectory = annotationsDirectory
    }

    public static func defaults(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AppleBooksDatabasePaths {
        let documents = homeDirectory
            .appendingPathComponent("Library/Containers/com.apple.iBooksX/Data/Documents", isDirectory: true)
        return AppleBooksDatabasePaths(
            libraryDirectory: documents.appendingPathComponent("BKLibrary", isDirectory: true),
            annotationsDirectory: documents.appendingPathComponent("AEAnnotation", isDirectory: true)
        )
    }
}

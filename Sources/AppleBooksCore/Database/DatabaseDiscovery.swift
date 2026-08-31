import Foundation

public enum AppleBooksStore: String, Equatable, Sendable {
    case library
    case annotations
}

public enum DatabaseDiscoveryError: Error, Equatable, Sendable {
    case missing(AppleBooksStore)
    case ambiguous(AppleBooksStore, candidates: [String])
    case invalidOverride(AppleBooksStore)
}

public struct DiscoveredAppleBooksDatabases: Equatable, Sendable {
    public let libraryDB: URL
    public let annotationsDB: URL
}

public struct DatabaseDiscovery: Sendable {
    public let paths: AppleBooksDatabasePaths

    public init(paths: AppleBooksDatabasePaths = .defaults()) {
        self.paths = paths
    }

    public func discover(
        libraryOverride: URL? = nil,
        annotationsOverride: URL? = nil
    ) throws -> DiscoveredAppleBooksDatabases {
        let libraryDB = try resolve(
            store: .library,
            override: libraryOverride,
            directory: paths.libraryDirectory,
            prefix: "BKLibrary"
        )
        let annotationsDB = try resolve(
            store: .annotations,
            override: annotationsOverride,
            directory: paths.annotationsDirectory,
            prefix: "AEAnnotation"
        )
        return DiscoveredAppleBooksDatabases(libraryDB: libraryDB, annotationsDB: annotationsDB)
    }

    private func resolve(
        store: AppleBooksStore,
        override: URL?,
        directory: URL,
        prefix: String
    ) throws -> URL {
        if let override {
            return try validatedOverride(override, store: store)
        }
        return try discoverSingleDatabase(in: directory, prefix: prefix, store: store)
    }

    private func discoverSingleDatabase(
        in directory: URL,
        prefix: String,
        store: AppleBooksStore
    ) throws -> URL {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DatabaseDiscoveryError.missing(store)
        }

        let candidates = entries.compactMap { entry -> URL? in
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite") else { return nil }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            return entry.standardizedFileURL.resolvingSymlinksInPath()
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        switch candidates.count {
        case 0:
            throw DatabaseDiscoveryError.missing(store)
        case 1:
            return candidates[0]
        default:
            throw DatabaseDiscoveryError.ambiguous(
                store,
                candidates: candidates.map(\.lastPathComponent)
            )
        }
    }

    private func validatedOverride(_ url: URL, store: AppleBooksStore) throws -> URL {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else {
                throw DatabaseDiscoveryError.invalidOverride(store)
            }
        } catch is DatabaseDiscoveryError {
            throw DatabaseDiscoveryError.invalidOverride(store)
        } catch {
            throw DatabaseDiscoveryError.invalidOverride(store)
        }
        return canonical
    }
}

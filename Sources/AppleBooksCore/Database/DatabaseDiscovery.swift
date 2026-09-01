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

enum DatabaseStoreProbeError: Error, Equatable {
    case missing
    case permission
    case ambiguous(candidates: [String])
    case invalidOverride
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
        let libraryDB = try resolve(store: .library, override: libraryOverride)
        let annotationsDB = try resolve(store: .annotations, override: annotationsOverride)
        return DiscoveredAppleBooksDatabases(libraryDB: libraryDB, annotationsDB: annotationsDB)
    }

    func probe(store: AppleBooksStore, override: URL? = nil) -> Result<URL, DatabaseStoreProbeError> {
        let directory: URL
        let prefix: String
        switch store {
        case .library:
            directory = paths.libraryDirectory
            prefix = "BKLibrary"
        case .annotations:
            directory = paths.annotationsDirectory
            prefix = "AEAnnotation"
        }

        if let override {
            return validatedOverride(override)
        }
        return discoverSingleDatabase(in: directory, prefix: prefix)
    }

    private func resolve(store: AppleBooksStore, override: URL?) throws -> URL {
        switch probe(store: store, override: override) {
        case let .success(url):
            return url
        case let .failure(error):
            switch error {
            case .missing, .permission:
                if override != nil { throw DatabaseDiscoveryError.invalidOverride(store) }
                throw DatabaseDiscoveryError.missing(store)
            case let .ambiguous(candidates):
                throw DatabaseDiscoveryError.ambiguous(store, candidates: candidates)
            case .invalidOverride:
                throw DatabaseDiscoveryError.invalidOverride(store)
            }
        }
    }

    private func discoverSingleDatabase(
        in directory: URL,
        prefix: String
    ) -> Result<URL, DatabaseStoreProbeError> {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            return .failure(Self.isPermissionError(error) ? .permission : .missing)
        }

        var sawPermissionFailure = false
        let candidates = entries.compactMap { entry -> URL? in
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(".sqlite") else { return nil }
            do {
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return entry.standardizedFileURL.resolvingSymlinksInPath()
            } catch {
                if Self.isPermissionError(error) { sawPermissionFailure = true }
                return nil
            }
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        switch candidates.count {
        case 0:
            return .failure(sawPermissionFailure ? .permission : .missing)
        case 1:
            return .success(candidates[0])
        default:
            return .failure(.ambiguous(candidates: candidates.map(\.lastPathComponent)))
        }
    }

    private func validatedOverride(_ url: URL) -> Result<URL, DatabaseStoreProbeError> {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        do {
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else {
                return .failure(.invalidOverride)
            }
            return .success(canonical)
        } catch {
            return .failure(Self.isPermissionError(error) ? .permission : .invalidOverride)
        }
    }

    private static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(EACCES) || nsError.code == Int(EPERM) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionError(underlying)
        }
        return false
    }
}

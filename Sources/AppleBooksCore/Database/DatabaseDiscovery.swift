import Darwin
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

protocol DatabaseDirectoryAccess: Sendable {
    func forEachEntryName(in directory: URL, _ body: (String) -> Void) throws
    func isRegularVisibleFile(_ url: URL) throws -> Bool
}

struct POSIXDatabaseDirectoryAccess: DatabaseDirectoryAccess {
    func forEachEntryName(in directory: URL, _ body: (String) -> Void) throws {
        errno = 0
        guard let handle = opendir(directory.path) else {
            throw Self.error(errno)
        }
        defer { closedir(handle) }

        while true {
            errno = 0
            guard let entry = readdir(handle) else {
                if errno != 0 { throw Self.error(errno) }
                return
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length + 1) {
                    FileManager.default.string(withFileSystemRepresentation: $0, length: length)
                }
            }
            guard name != ".", name != "..", name.hasPrefix(".") == false else { continue }
            body(name)
        }
    }

    func isRegularVisibleFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isHiddenKey])
        return values.isRegularFile == true && values.isHidden != true
    }

    private static func error(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

struct DatabaseCandidateAccumulator: Equatable {
    static let maximumWitnesses = 8

    private(set) var candidateCount = 0
    private(set) var witnesses: [String] = []

    mutating func record(_ name: String) {
        candidateCount = min(2, candidateCount + 1)
        let insertion = witnesses.firstIndex(where: { name.utf8.lexicographicallyPrecedes($0.utf8) }) ?? witnesses.endIndex
        if insertion < Self.maximumWitnesses {
            witnesses.insert(name, at: insertion)
            if witnesses.count > Self.maximumWitnesses { witnesses.removeLast() }
        } else if witnesses.count < Self.maximumWitnesses {
            witnesses.append(name)
        }
    }
}

public struct DatabaseDiscovery: Sendable {
    public let paths: AppleBooksDatabasePaths
    private let directoryAccess: any DatabaseDirectoryAccess

    public init(paths: AppleBooksDatabasePaths = .defaults()) {
        self.paths = paths
        directoryAccess = POSIXDatabaseDirectoryAccess()
    }

    init(paths: AppleBooksDatabasePaths, directoryAccess: any DatabaseDirectoryAccess) {
        self.paths = paths
        self.directoryAccess = directoryAccess
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

    package func resolve(store: AppleBooksStore, override: URL?) throws -> URL {
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
        var sawPermissionFailure = false
        var candidates = DatabaseCandidateAccumulator()
        do {
            try directoryAccess.forEachEntryName(in: directory) { name in
                guard name.hasPrefix(prefix), name.hasSuffix(".sqlite") else { return }
                let entry = directory.appendingPathComponent(name, isDirectory: false)
                do {
                    guard try directoryAccess.isRegularVisibleFile(entry) else { return }
                    candidates.record(name)
                } catch {
                    if Self.isPermissionError(error) { sawPermissionFailure = true }
                }
            }
        } catch {
            return .failure(Self.isPermissionError(error) ? .permission : .missing)
        }

        switch candidates.candidateCount {
        case 0:
            return .failure(sawPermissionFailure ? .permission : .missing)
        case 1:
            guard let name = candidates.witnesses.first else { return .failure(.missing) }
            return .success(
                directory.appendingPathComponent(name, isDirectory: false)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
            )
        default:
            return .failure(.ambiguous(candidates: candidates.witnesses))
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

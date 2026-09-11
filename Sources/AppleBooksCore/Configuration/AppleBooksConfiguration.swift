import Darwin
import Foundation

public struct HistoricalBookMetadata: Equatable, Sendable {
    public let title: String
    public let author: String

    public init(title: String, author: String) {
        self.title = title
        self.author = author
    }
}

public enum AppleBooksConfigurationError: Error, Equatable, Sendable {
    case invalidConfiguration
}

struct HistoricalAssets: Equatable, Sendable {
    private let entries: [String: HistoricalBookMetadata]

    init(entries: [String: HistoricalBookMetadata] = [:]) {
        self.entries = entries
    }

    func metadata(for assetID: String) -> HistoricalBookMetadata? {
        entries[assetID]
    }
}

public struct AppleBooksConfiguration: Equatable, Sendable {
    let historicalAssets: HistoricalAssets
    public let epubRoot: URL?

    static let empty = AppleBooksConfiguration(
        historicalAssets: HistoricalAssets(),
        epubRoot: nil
    )

    private init(historicalAssets: HistoricalAssets, epubRoot: URL?) {
        self.historicalAssets = historicalAssets
        self.epubRoot = epubRoot
    }

    static func loadDefault() throws -> AppleBooksConfiguration {
        try AppleBooksConfiguration(fileURL: defaultFileURL)
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/applebookscli/config.json")
    }

    public init(fileURL: URL) throws {
        do {
            guard let data = try ConfigurationResourcePolicy.read(fileURL) else {
                historicalAssets = HistoricalAssets()
                epubRoot = nil
                return
            }
            let decoded = try JSONDecoder().decode(FileConfiguration.self, from: data)
            guard decoded.historicalAssets.count <= ConfigurationResourcePolicy.maximumHistoricalAssets else {
                throw AppleBooksConfigurationError.invalidConfiguration
            }

            var entries: [String: HistoricalBookMetadata] = [:]
            entries.reserveCapacity(decoded.historicalAssets.count)
            for (assetID, entry) in decoded.historicalAssets {
                guard PublicStableIdentityPolicy.isEligible(assetID),
                      entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                      ConfigurationResourcePolicy.acceptsMetadata(entry.title),
                      ConfigurationResourcePolicy.acceptsMetadata(entry.author) else {
                    throw AppleBooksConfigurationError.invalidConfiguration
                }
                entries[assetID] = HistoricalBookMetadata(title: entry.title, author: entry.author)
            }
            historicalAssets = HistoricalAssets(entries: entries)

            if let rawRoot = decoded.epubRoot {
                guard rawRoot.utf8.count <= ConfigurationResourcePolicy.maximumEpubRootUTF8Bytes,
                      rawRoot.utf8.contains(0) == false else {
                    throw AppleBooksConfigurationError.invalidConfiguration
                }
                let trimmed = rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.isEmpty == false else {
                    throw AppleBooksConfigurationError.invalidConfiguration
                }
                let expanded: String
                if trimmed.hasPrefix("~/") {
                    expanded = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(String(trimmed.dropFirst(2)))
                        .path
                } else {
                    expanded = trimmed
                }
                epubRoot = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
            } else {
                epubRoot = nil
            }
        } catch is AppleBooksConfigurationError {
            throw AppleBooksConfigurationError.invalidConfiguration
        } catch {
            throw AppleBooksConfigurationError.invalidConfiguration
        }
    }
}

private enum ConfigurationResourcePolicy {
    static let maximumFileBytes = 1 * 1_024 * 1_024
    static let maximumHistoricalAssets = 10_000
    static let maximumMetadataGraphemes = 512
    static let maximumMetadataUTF8Bytes = 8 * 1_024
    static let maximumEpubRootUTF8Bytes = 4_096
    private static let readChunkBytes = 64 * 1_024

    static func acceptsMetadata(_ value: String) -> Bool {
        value.count <= maximumMetadataGraphemes && value.utf8.count <= maximumMetadataUTF8Bytes
    }

    static func read(_ fileURL: URL) throws -> Data? {
        guard fileURL.isFileURL else {
            throw AppleBooksConfigurationError.invalidConfiguration
        }
        let descriptor = fileURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw AppleBooksConfigurationError.invalidConfiguration
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumFileBytes else {
            throw AppleBooksConfigurationError.invalidConfiguration
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        while true {
            let remaining = maximumFileBytes - data.count
            let chunk = try handle.read(upToCount: min(readChunkBytes, remaining + 1)) ?? Data()
            guard chunk.isEmpty == false else { return data }
            guard chunk.count <= remaining else {
                throw AppleBooksConfigurationError.invalidConfiguration
            }
            data.append(chunk)
        }
    }
}

private struct FileConfiguration: Decodable {
    let historicalAssets: [String: HistoricalEntry]
    let epubRoot: String?

    private enum CodingKeys: String, CodingKey {
        case historicalAssets = "historical_assets"
        case epubRoot = "epub_root"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        historicalAssets = container.contains(.historicalAssets)
            ? try container.decode([String: HistoricalEntry].self, forKey: .historicalAssets)
            : [:]
        epubRoot = container.contains(.epubRoot)
            ? try container.decode(String.self, forKey: .epubRoot)
            : nil
    }
}

private struct HistoricalEntry: Decodable {
    let title: String
    let author: String
}

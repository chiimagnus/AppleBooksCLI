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

    static func loadDefault() throws -> AppleBooksConfiguration {
        try AppleBooksConfiguration(fileURL: defaultFileURL)
    }

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/applebookscli/config.json")
    }

    public init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            historicalAssets = HistoricalAssets()
            epubRoot = nil
            return
        }

        do {
            let decoded = try JSONDecoder().decode(FileConfiguration.self, from: Data(contentsOf: fileURL))
            var entries: [String: HistoricalBookMetadata] = [:]
            entries.reserveCapacity(decoded.historicalAssets.count)
            for (assetID, entry) in decoded.historicalAssets {
                guard assetID.isEmpty == false,
                      entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw AppleBooksConfigurationError.invalidConfiguration
                }
                entries[assetID] = HistoricalBookMetadata(title: entry.title, author: entry.author)
            }
            historicalAssets = HistoricalAssets(entries: entries)

            if let rawRoot = decoded.epubRoot {
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

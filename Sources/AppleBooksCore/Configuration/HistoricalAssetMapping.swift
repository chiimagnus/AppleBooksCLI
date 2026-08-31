import Foundation

public struct HistoricalBookMetadata: Equatable, Sendable {
    public let title: String
    public let author: String

    public init(title: String, author: String) {
        self.title = title
        self.author = author
    }
}

public enum HistoricalAssetMappingError: Error, Equatable, Sendable {
    case invalidConfiguration
}

struct HistoricalAssetMapping: Equatable, Sendable {
    private struct Config: Decodable {
        let historical_assets: [String: Entry]
    }

    private struct Entry: Decodable {
        let title: String
        let author: String
    }

    private let entries: [String: HistoricalBookMetadata]

    static func loadDefault() throws -> HistoricalAssetMapping {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/applebookscli/config.json")
        return try HistoricalAssetMapping(fileURL: url)
    }

    init(fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            entries = [:]
            return
        }

        do {
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: fileURL))
            var decoded: [String: HistoricalBookMetadata] = [:]
            decoded.reserveCapacity(config.historical_assets.count)
            for (assetID, entry) in config.historical_assets {
                guard assetID.isEmpty == false,
                      entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw HistoricalAssetMappingError.invalidConfiguration
                }
                decoded[assetID] = HistoricalBookMetadata(title: entry.title, author: entry.author)
            }
            entries = decoded
        } catch is HistoricalAssetMappingError {
            throw HistoricalAssetMappingError.invalidConfiguration
        } catch {
            throw HistoricalAssetMappingError.invalidConfiguration
        }
    }

    func metadata(for assetID: String) -> HistoricalBookMetadata? {
        entries[assetID]
    }
}

import Foundation
import Testing
@testable import AppleBooksCore

@Suite("HistoricalAssetMappingTests")
struct HistoricalAssetMappingTests {
    @Test
    func missingConfigIsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mapping = try HistoricalAssetMapping(fileURL: directory.appendingPathComponent("missing.json"))
        #expect(mapping.metadata(for: "asset") == nil)
    }

    @Test
    func loadsExactSyntheticAssetMetadata() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("""
        {
          "epub_root": "/synthetic/unused",
          "historical_assets": {
            "asset-history": {"title": "Synthetic History", "author": "Example Author"}
          }
        }
        """.utf8).write(to: file)

        let mapping = try HistoricalAssetMapping(fileURL: file)
        #expect(mapping.metadata(for: "asset-history") == HistoricalBookMetadata(
            title: "Synthetic History",
            author: "Example Author"
        ))
        #expect(mapping.metadata(for: "other") == nil)
    }

    @Test
    func invalidShapeFailsWithSanitizedError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("""
        {"historical_assets":{"private-id":{"title":"","author":"private-author"}}}
        """.utf8).write(to: file)

        #expect(throws: HistoricalAssetMappingError.invalidConfiguration) {
            _ = try HistoricalAssetMapping(fileURL: file)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

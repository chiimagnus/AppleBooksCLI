import Foundation
import Testing
@testable import AppleBooksCore

@Suite("AppleBooksConfigurationTests")
struct AppleBooksConfigurationTests {
    @Test
    func missingConfigMakesBothCapabilitiesEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = try AppleBooksConfiguration(fileURL: directory.appendingPathComponent("missing.json"))
        #expect(configuration.historicalAssets.metadata(for: "asset") == nil)
        #expect(configuration.epubRoot == nil)
    }

    @Test
    func loadsHistoricalMetadataAndCanonicalEpubRootIndependently() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let epubRoot = directory.appendingPathComponent("epubs", isDirectory: true)
        try FileManager.default.createDirectory(at: epubRoot, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("config.json")
        let data = try JSONSerialization.data(withJSONObject: [
            "epub_root": "  \(epubRoot.path)/../epubs  ",
            "historical_assets": [
                "asset-history": ["title": "Synthetic History", "author": "Example Author"],
            ],
        ])
        try data.write(to: file)

        let configuration = try AppleBooksConfiguration(fileURL: file)
        #expect(configuration.historicalAssets.metadata(for: "asset-history") == HistoricalBookMetadata(
            title: "Synthetic History",
            author: "Example Author"
        ))
        #expect(configuration.historicalAssets.metadata(for: "other") == nil)
        #expect(configuration.epubRoot == epubRoot.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func missingIndividualFieldsStayEmptyWithoutASecondParser() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let onlyHistory = directory.appendingPathComponent("history.json")
        try Data("{\"historical_assets\":{}}".utf8).write(to: onlyHistory)
        #expect(try AppleBooksConfiguration(fileURL: onlyHistory).epubRoot == nil)

        let onlyRoot = directory.appendingPathComponent("root.json")
        try Data("{\"epub_root\":\"/synthetic/epubs\"}".utf8).write(to: onlyRoot)
        let configuration = try AppleBooksConfiguration(fileURL: onlyRoot)
        #expect(configuration.historicalAssets.metadata(for: "asset") == nil)
        #expect(configuration.epubRoot?.path == "/synthetic/epubs")
    }

    @Test
    func invalidPresentFieldsFailWithSanitizedError() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidDocuments = [
            "{\"historical_assets\":null}",
            "{\"epub_root\":null}",
            "{\"epub_root\":\"   \"}",
            "{\"historical_assets\":{\"private-id\":{\"title\":\"\",\"author\":\"private-author\"}}}",
        ]
        for (index, document) in invalidDocuments.enumerated() {
            let file = directory.appendingPathComponent("invalid-\(index).json")
            try Data(document.utf8).write(to: file)
            #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
                _ = try AppleBooksConfiguration(fileURL: file)
            }
        }
    }

    @Test
    func tildeRootExpandsAgainstCurrentHomeAndCanonicalizes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data("{\"epub_root\":\"~/synthetic-epubs\"}".utf8).write(to: file)
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("synthetic-epubs")
            .standardizedFileURL
            .resolvingSymlinksInPath()
        #expect(try AppleBooksConfiguration(fileURL: file).epubRoot == expected)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

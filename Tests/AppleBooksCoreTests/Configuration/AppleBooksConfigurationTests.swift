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
    func configurationFileMustBeRegularAndNoLargerThanOneMiB() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
            _ = try AppleBooksConfiguration(fileURL: directory)
        }

        let file = directory.appendingPathComponent("config.json")
        var exact = Data("{}".utf8)
        exact.append(Data(repeating: 0x20, count: 1 * 1_024 * 1_024 - exact.count))
        #expect(exact.count == 1 * 1_024 * 1_024)
        try exact.write(to: file)
        _ = try AppleBooksConfiguration(fileURL: file)

        var oversized = exact
        oversized.append(0x20)
        try oversized.write(to: file)
        #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
            _ = try AppleBooksConfiguration(fileURL: file)
        }
    }

    @Test
    func historicalAssetsAreCountBoundedAndUsePublicStableIdentities() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")

        var assets: [String: [String: String]] = [:]
        for index in 0..<10_000 {
            assets["asset-\(index)"] = ["title": "T", "author": "A"]
        }
        try writeConfiguration(["historical_assets": assets], to: file)
        #expect(try AppleBooksConfiguration(fileURL: file).historicalAssets.metadata(for: "asset-9999")?.title == "T")

        assets["asset-overflow"] = ["title": "T", "author": "A"]
        try writeConfiguration(["historical_assets": assets], to: file)
        #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
            _ = try AppleBooksConfiguration(fileURL: file)
        }

        let maximumIdentity = String(repeating: "a", count: 2_048)
        try writeConfiguration([
            "historical_assets": [maximumIdentity: ["title": "T", "author": "A"]],
        ], to: file)
        #expect(try AppleBooksConfiguration(fileURL: file).historicalAssets.metadata(for: maximumIdentity) != nil)

        for invalidIdentity in [
            String(repeating: "a", count: 2_049),
            " padded",
            "padded ",
            "before\0after",
        ] {
            try writeConfiguration([
                "historical_assets": [invalidIdentity: ["title": "T", "author": "A"]],
            ], to: file)
            #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
                _ = try AppleBooksConfiguration(fileURL: file)
            }
        }
    }

    @Test
    func historicalMetadataUsesMetadataTextBudgetWithoutTruncation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")

        let maximumTitle = String(repeating: "t", count: 512)
        let family = "👨‍👩‍👧‍👦"
        let maximumByteAuthor = String(repeating: family, count: 327) + String(repeating: "a", count: 17)
        #expect(maximumByteAuthor.count == 344)
        #expect(maximumByteAuthor.utf8.count == 8 * 1_024)
        try writeConfiguration([
            "historical_assets": [
                "asset": ["title": maximumTitle, "author": maximumByteAuthor],
            ],
        ], to: file)
        let configuration = try AppleBooksConfiguration(fileURL: file)
        #expect(configuration.historicalAssets.metadata(for: "asset") == HistoricalBookMetadata(
            title: maximumTitle,
            author: maximumByteAuthor
        ))

        for invalidEntry in [
            ["title": String(repeating: "t", count: 513), "author": "A"],
            ["title": "T", "author": maximumByteAuthor + "a"],
        ] {
            try writeConfiguration([
                "historical_assets": ["asset": invalidEntry],
            ], to: file)
            #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
                _ = try AppleBooksConfiguration(fileURL: file)
            }
        }
    }

    @Test
    func epubRootUsesRawFourKiBBudgetBeforeExistingCanonicalization() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")

        let maximumRoot = "/" + String(repeating: "a", count: 4_095)
        #expect(maximumRoot.utf8.count == 4_096)
        try writeConfiguration(["epub_root": maximumRoot], to: file)
        #expect(try AppleBooksConfiguration(fileURL: file).epubRoot != nil)

        let oversizedRoot = maximumRoot + "a"
        try writeConfiguration(["epub_root": oversizedRoot], to: file)
        #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
            _ = try AppleBooksConfiguration(fileURL: file)
        }

        try writeConfiguration(["epub_root": "before\0after"], to: file)
        #expect(throws: AppleBooksConfigurationError.invalidConfiguration) {
            _ = try AppleBooksConfiguration(fileURL: file)
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

    private func writeConfiguration(_ object: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

import AppleBooksCore
import ArgumentParser
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("CLIContextTests")
struct CLIContextTests {
    @Test
    func globalOptionsAreLeafLocalAndParseAfterTheCommandPath() throws {
        let parsed = try TestLeaf.parse([
            "--json",
            "--verbose",
            "--config", "/tmp/config.json",
            "--library-db", "/tmp/library.sqlite",
            "--annotations-db", "/tmp/annotations.sqlite",
        ])

        #expect(parsed.global.json)
        #expect(parsed.global.verbose)
        #expect(parsed.global.config == "/tmp/config.json")
        #expect(parsed.global.libraryDB == "/tmp/library.sqlite")
        #expect(parsed.global.annotationsDB == "/tmp/annotations.sqlite")
        #expect(throws: (any Error).self) {
            _ = try AppleBooksCLI.parseAsRoot(["--json"])
        }
    }

    @Test
    func contextInitializationDoesNotDiscoverDatabases() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let discovery = DatabaseDiscovery(
            paths: AppleBooksDatabasePaths(
                libraryDirectory: root.appendingPathComponent("missing-library", isDirectory: true),
                annotationsDirectory: root.appendingPathComponent("missing-annotations", isDirectory: true)
            )
        )

        let context = CLIContext(global: try GlobalOptions.parse([]), databaseDiscovery: discovery)
        #expect(context.configurationFile == nil)
        #expect(throws: DatabaseDiscoveryError.missing(.library)) {
            _ = try context.databases()
        }
    }

    @Test
    func libraryAndAnnotationOverridesRemainIndependent() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }

        var libraryOnly = try GlobalOptions.parse([])
        libraryOnly.libraryDB = fixture.libraryOverride.path
        let libraryResolved = try CLIContext(
            global: libraryOnly,
            databaseDiscovery: fixture.discovery
        ).databases()
        #expect(libraryResolved.libraryDB == fixture.libraryOverride.resolvingSymlinksInPath())
        #expect(libraryResolved.annotationsDB == fixture.defaultAnnotations.resolvingSymlinksInPath())

        var annotationsOnly = try GlobalOptions.parse([])
        annotationsOnly.annotationsDB = fixture.annotationsOverride.path
        let annotationsResolved = try CLIContext(
            global: annotationsOnly,
            databaseDiscovery: fixture.discovery
        ).databases()
        #expect(annotationsResolved.libraryDB == fixture.defaultLibrary.resolvingSymlinksInPath())
        #expect(annotationsResolved.annotationsDB == fixture.annotationsOverride.resolvingSymlinksInPath())
    }

    @Test
    func bothOverridesNeedNoDefaultStoreFiles() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try regularFile(root.appendingPathComponent("library.sqlite"))
        let annotations = try regularFile(root.appendingPathComponent("annotations.sqlite"))
        let discovery = DatabaseDiscovery(
            paths: AppleBooksDatabasePaths(
                libraryDirectory: root.appendingPathComponent("absent-library", isDirectory: true),
                annotationsDirectory: root.appendingPathComponent("absent-annotations", isDirectory: true)
            )
        )
        var global = try GlobalOptions.parse([])
        global.libraryDB = library.path
        global.annotationsDB = annotations.path

        let resolved = try CLIContext(global: global, databaseDiscovery: discovery).databases()
        #expect(resolved.libraryDB == library.resolvingSymlinksInPath())
        #expect(resolved.annotationsDB == annotations.resolvingSymlinksInPath())
    }

    @Test
    func explicitConfigurationIsPassedAsTheOnlySelectedFile() throws {
        var global = try GlobalOptions.parse([])
        global.config = "/tmp/explicit-config.json"
        let context = CLIContext(global: global)

        #expect(context.configurationFile?.path == "/tmp/explicit-config.json")
        #expect(CLIContext(global: try GlobalOptions.parse([])).configurationFile == nil)
    }

    @Test
    func invalidDatabaseOverrideFailsThroughCoreDiscovery() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        var global = try GlobalOptions.parse([])
        global.libraryDB = fixture.root.path

        #expect(throws: DatabaseDiscoveryError.invalidOverride(.library)) {
            _ = try CLIContext(global: global, databaseDiscovery: fixture.discovery).databases()
        }
    }

    private struct TestLeaf: ParsableCommand {
        @OptionGroup var global: GlobalOptions
    }

    private final class DiscoveryFixture {
        let root: URL
        let defaultLibrary: URL
        let defaultAnnotations: URL
        let libraryOverride: URL
        let annotationsOverride: URL
        let discovery: DatabaseDiscovery

        init() throws {
            root = CLIContextTests().temporaryDirectory()
            let libraryDirectory = root.appendingPathComponent("library", isDirectory: true)
            let annotationsDirectory = root.appendingPathComponent("annotations", isDirectory: true)
            try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: annotationsDirectory, withIntermediateDirectories: true)
            defaultLibrary = try CLIContextTests().regularFile(
                libraryDirectory.appendingPathComponent("BKLibrary-default.sqlite")
            )
            defaultAnnotations = try CLIContextTests().regularFile(
                annotationsDirectory.appendingPathComponent("AEAnnotation-default.sqlite")
            )
            libraryOverride = try CLIContextTests().regularFile(root.appendingPathComponent("library-override.sqlite"))
            annotationsOverride = try CLIContextTests().regularFile(root.appendingPathComponent("annotations-override.sqlite"))
            discovery = DatabaseDiscovery(
                paths: AppleBooksDatabasePaths(
                    libraryDirectory: libraryDirectory,
                    annotationsDirectory: annotationsDirectory
                )
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func regularFile(_ url: URL) throws -> URL {
        try Data().write(to: url)
        return url
    }
}

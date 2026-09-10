import AppleBooksCore
import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("CLIContextTests")
struct CLIContextTests {
    @Test
    func globalOptionsAreLeafLocalAndParseAfterTheCommandPath() throws {
        let parsed = try TestLeaf.parse([
            "--config", "/tmp/config.json",
            "--library-db", "/tmp/library.sqlite",
            "--annotations-db", "/tmp/annotations.sqlite",
        ])

        #expect(parsed.global.config == "/tmp/config.json")
        #expect(parsed.global.libraryDB == "/tmp/library.sqlite")
        #expect(parsed.global.annotationsDB == "/tmp/annotations.sqlite")
        #expect(throws: (any Error).self) {
            _ = try TestLeaf.parse(["--json"])
        }
        #expect(throws: (any Error).self) {
            _ = try TestLeaf.parse(["--verbose"])
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
    }

    @Test
    func libraryAndAnnotationOverridesRemainIndependent() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }

        var libraryOnly = try GlobalOptions.parse([])
        libraryOnly.libraryDB = fixture.libraryOverride.path
        let libraryContext = CLIContext(global: libraryOnly, databaseDiscovery: fixture.discovery)
        _ = try libraryContext.makeAppleBooks(dependencies: .libraryRead)
        #expect(libraryContext.managesCollectionBooksApplication == false)
        #expect(libraryContext.managesAnnotationBooksApplication)

        var annotationsOnly = try GlobalOptions.parse([])
        annotationsOnly.annotationsDB = fixture.annotationsOverride.path
        let annotationsContext = CLIContext(global: annotationsOnly, databaseDiscovery: fixture.discovery)
        _ = try annotationsContext.makeAppleBooks(dependencies: .annotationsRead)
        #expect(annotationsContext.managesCollectionBooksApplication)
        #expect(annotationsContext.managesAnnotationBooksApplication == false)
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

        _ = try CLIContext(global: global, databaseDiscovery: discovery).makeAppleBooks(
            dependencies: [.libraryRead, .annotationsRead]
        )
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
    func libraryOnlyCompositionIgnoresBrokenAnnotationsAndConfiguration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZTITLE TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1, 'Only Library');
        """)
        let badConfig = root.appendingPathComponent("bad-config.json")
        try Data("not-json".utf8).write(to: badConfig)
        var global = try GlobalOptions.parse([])
        global.libraryDB = library.path
        global.annotationsDB = root.appendingPathComponent("missing-annotations.sqlite").path
        global.config = badConfig.path

        let books = try CLIContext(global: global).makeAppleBooks(dependencies: .libraryRead)

        #expect(try books.listBooks().map(\.localPK) == [1])
        #expect(throws: AppleBooksDependencyError.unavailable(.annotationsRead)) {
            _ = try books.listAnnotations()
        }
    }

    @Test
    func annotationWriteCompositionIgnoresMissingLibraryAndBrokenConfiguration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY);
        """)
        let badConfig = root.appendingPathComponent("bad-config.json")
        try Data("not-json".utf8).write(to: badConfig)
        var global = try GlobalOptions.parse([])
        global.libraryDB = root.appendingPathComponent("missing-library.sqlite").path
        global.annotationsDB = annotations.path
        global.config = badConfig.path

        let books = try CLIContext(global: global).makeAppleBooks(dependencies: .annotationWrite)

        #expect(throws: AppleBooksDependencyError.unavailable(.libraryRead)) {
            _ = try books.listBooks()
        }
    }

    @Test
    func annotatedBookCompositionNeedsAnnotationsButNotConfiguration() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library.sqlite")
        let annotations = root.appendingPathComponent("annotations.sqlite")
        try createDatabase(library, sql: """
        CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY, ZASSETID TEXT, ZTITLE TEXT);
        INSERT INTO ZBKLIBRARYASSET VALUES (1, 'asset-a', 'Annotated');
        """)
        try createDatabase(annotations, sql: """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONASSETID TEXT
        );
        INSERT INTO ZAEANNOTATION VALUES (1, 0, 1, 'asset-a');
        """)
        let badConfig = root.appendingPathComponent("bad-config.json")
        try Data("not-json".utf8).write(to: badConfig)
        var global = try GlobalOptions.parse([])
        global.libraryDB = library.path
        global.annotationsDB = annotations.path
        global.config = badConfig.path

        let books = try CLIContext(global: global).makeAppleBooks(
            dependencies: [.libraryRead, .annotationsRead]
        )

        #expect(try books.annotatedBooks().map { $0.book.localPK } == [1])
    }

    @Test
    func pdfWorkerDependencyFailureUsesCanonicalUnavailableError() throws {
        #expect(throws: CLIError.unavailable("PDF worker is unavailable.")) {
            try CLIOperation.run {
                throw AppleBooksDependencyError.unavailable(.pdfWorker)
            }
        }
    }

    @Test
    func invalidDatabaseOverrideFailsThroughCoreDiscovery() throws {
        let fixture = try DiscoveryFixture()
        defer { fixture.remove() }
        var global = try GlobalOptions.parse([])
        global.libraryDB = fixture.root.path

        #expect(throws: DatabaseDiscoveryError.invalidOverride(.library)) {
            _ = try CLIContext(global: global, databaseDiscovery: fixture.discovery).makeAppleBooks(
                dependencies: .libraryRead
            )
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
    private func createDatabase(_ url: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw TestError.database
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.database
        }
    }

    private enum TestError: Error {
        case database
    }

}

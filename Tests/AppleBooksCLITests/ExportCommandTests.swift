import ArgumentParser
import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("ExportCommandTests")
struct ExportCommandTests {
    @Test
    func defaultsComeFromCoreExportOptionsAndRequireExplicitOutput() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-default.json")
        let command = try ExportCommand.parse(["--format", "json", "--output", output.path])
        let request = try command.makeRequest()

        #expect(request.options == (try ExportOptions()))
        #expect(request.overwrite == .never)
        #expect(request.outputURL.path == output.standardizedFileURL.path)
        #expect(request.producesMultipleFiles == false)

        #expect(throws: (any Error).self) {
            _ = try ExportCommand.parse(["--format", "json"])
        }
    }

    @Test
    func helpMarksOutputAsRequired() {
        let capture = Capture()
        let code = CLIEntrypoint.run(arguments: ["export", "--help"], output: capture.output)

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        let normalized = capture.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(normalized.contains("USAGE: applebookscli export"))
        #expect(normalized.contains("--output <output>"))
    }

    @Test
    func everySelectionMapsToExistingCoreOwners() throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("export-command-map", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "markdown",
            "--book", "asset-a",
            "--book", "asset-b",
            "--book-pk", "11",
            "--book-pk", "12",
            "--has-highlight", "false",
            "--has-note", "true",
            "--color", "yellow",
            "--color", "blue",
            "--underline", "true",
            "--grouping", "per-document",
            "--overwrite", "always",
            "--output", output.path,
        ])
        let request = try command.makeRequest()

        #expect(request.options.bookSelectors == [
            .assetID("asset-a"),
            .assetID("asset-b"),
            .localPK(11),
            .localPK(12),
        ])
        #expect(request.options.hasHighlight == false)
        #expect(request.options.hasNote == true)
        #expect(request.options.colors == [.yellow, .blue])
        #expect(request.options.underline == true)
        #expect(request.options.grouping == .perDocument)
        #expect(request.overwrite == .always)
        #expect(request.outputURL.path == output.standardizedFileURL.path)
        #expect(request.producesMultipleFiles)
    }

    @Test
    func presenceGrammarRejectsLegacyAndInvalidValuesBeforeIO() throws {
        for option in ["--has-highlight", "--has-note", "--underline"] {
            for value in ["true", "false"] {
                let request = try ExportCommand.parse([
                    "--format", "json", "--output", "/tmp/presence.json", option, value,
                ]).makeRequest()
                let actual = option == "--has-highlight" ? request.options.hasHighlight
                    : option == "--has-note" ? request.options.hasNote : request.options.underline
                #expect(actual == (value == "true"))
            }
            for invalid in ["yes", "1", "TRUE"] {
                #expect(throws: (any Error).self) {
                    _ = try ExportCommand.parse(["--format", "json", option, invalid])
                }
            }
        }
        for arguments in [["--kind", "highlight"], ["--underline"], ["--order", "reading"], ["--order", "source"], ["--skip-first", "1"], ["--overwrite", "smart"], ["--include-epub-metadata"], ["--cover", "inline"], ["--cover", "file"], ["--grouping", "per-book"]] {
            #expect(throws: (any Error).self) {
                _ = try ExportCommand.parse(["--format", "json"] + arguments)
            }
        }
    }

    @Test
    func invalidOptionsFailBeforeDatabaseIO() throws {
        let missing = "/definitely/missing/applebooks.sqlite"
        let global = ["--library-db", missing, "--annotations-db", missing]

        let invalidPK = try ExportCommand.parse([
            "--format", "json",
            "--book-pk", "1",
            "--book-pk", "0",
            "--book-pk", "2",
            "--output", "/tmp/export.json",
        ] + global)
        #expect(throws: CLIError.usageInvalid("--book-pk must be a positive local row identifier.")) {
            _ = try invalidPK.makeRequest()
        }

        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["export", "--format", "json"] + global,
            output: capture.output
        )
        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains("Database override") == false)
        #expect(capture.stderr.contains(missing) == false)
    }

    @Test
    func removedGlobalJsonFlagIsSanitizedParseFailure() throws {
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["export", "--format", "json", "--output", "/tmp/export.json", "--json"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(capture.stderr.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "Invalid command-line arguments.")
        #expect(capture.stderr.contains("--json") == false)
    }

    @Test
    func exactCurrentEPUBWorksWithoutWorkerDependency() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("exact-epub.json")
        let command = try ExportCommand.parse([
            "--format", "json",
            "--book", "asset-a",
            "--output", destination.path,
            "--library-db", fixture.library.path,
            "--annotations-db", fixture.annotations.path,
            "--config", fixture.configuration.path,
        ])
        let result = try command.execute()
        #expect(result.destination == destination.standardizedFileURL.path)
        #expect(result.disposition == .file)
        #expect(result.documentCount == 1)
        #expect(result.warningCount == 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func singleFileWritesArtifactAndOnlyCompactResultToStdout() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("annotations.json")
        let command = try ExportCommand.parse([
            "--format", "json",
            "--output", destination.path,
        ])
        let capture = Capture()

        let direct = try command.execute(using: fixture.core())
        try capture.output.writeJSON(direct)

        #expect(capture.stderr.isEmpty)
        let result = try JSONDecoder().decode(ExportRunResult.self, from: Data(capture.stdout.utf8))
        #expect(result.destination == destination.standardizedFileURL.path)
        #expect(result.disposition == .file)
        #expect(result.documentCount == 1)
        #expect(result.warningCount == 0)
        #expect(capture.stdout.contains("\"groups\"") == false)
        let artifact = String(decoding: try Data(contentsOf: destination), as: UTF8.self)
        #expect(artifact.contains("\"groups\""))
        #expect(artifact.contains("Quote A"))
    }

    @Test
    func genericPerDocumentExportReturnsDirectoryCountWithoutFileList() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("json-books", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "json",
            "--grouping", "per-document",
            "--output", directory.path,
        ])

        let result = try command.execute(using: fixture.core())

        #expect(result.destination == directory.standardizedFileURL.path)
        #expect(result.disposition == .directory)
        #expect(result.documentCount == 2)
        #expect(result.warningCount == 0)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 3)
        #expect(names.contains(ManagedExportManifestWriter.fileName))
        #expect(names.filter { $0 != ManagedExportManifestWriter.fileName }.count == 2)
        #expect(names.filter { $0 != ManagedExportManifestWriter.fileName }.allSatisfy { $0.hasSuffix(".json") })
    }

    @Test
    func managedDirectoryPublishSyncFailureReturnsStructuredSuccessWarning() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("sync-warning", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "json",
            "--grouping", "per-document",
            "--output", directory.path,
        ])

        let result = try command.execute(
            using: fixture.core(),
            managedDirectorySyncParentAfterPublish: { _ in false }
        )

        #expect(result.warningCount == 1)
        #expect(result.warnings.count == 1)
        let warning = try #require(result.warnings.first)
        #expect(warning.code == "export_directory_sync_failed")
        #expect(warning.source == "export")
        #expect(warning.reason == "managed_directory_parent_sync_failed")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 3)
        #expect(names.contains(ManagedExportManifestWriter.fileName))
    }

    @Test
    func defaultMarkdownIgnoresExtensionsAndGroupingAloneChoosesNodeType() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let defaultFile = fixture.root.appendingPathComponent("not-json.json")
        let explicitFile = fixture.root.appendingPathComponent("explicit")
        let directory = fixture.root.appendingPathComponent("documents.json")
        let defaultCommand = try ExportCommand.parse(["--output", defaultFile.path])
        let explicitCommand = try ExportCommand.parse(["--format", "markdown", "--output", explicitFile.path])
        let directoryCommand = try ExportCommand.parse(["--grouping", "per-document", "--output", directory.path])
        #expect(try defaultCommand.makeRequest().format == .markdown)
        #expect(try defaultCommand.execute(using: fixture.core()).disposition == .file)
        #expect(try explicitCommand.execute(using: fixture.core()).disposition == .file)
        #expect(try directoryCommand.execute(using: fixture.core()).disposition == .directory)
        #expect(try Data(contentsOf: defaultFile) == Data(contentsOf: explicitFile))
        #expect(try String(contentsOf: defaultFile, encoding: .utf8).hasPrefix("# Apple Books export"))
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.count == 3)
        #expect(names.contains(ManagedExportManifestWriter.fileName))
        #expect(names.filter { $0 != ManagedExportManifestWriter.fileName }.count == 2)
        #expect(names.filter { $0 != ManagedExportManifestWriter.fileName }.allSatisfy { $0.hasSuffix(".md") })
        let relative = try ExportCommand.parse(["--output", "relative"]).makeRequest(currentDirectory: fixture.root)
        #expect(relative.outputURL == fixture.root.appendingPathComponent("relative").standardizedFileURL)
        #expect(throws: (any Error).self) { _ = try ExportCommand.parse([]) }
    }

    @Test
    func wrongOutputNodeFailsWithoutReplacingExistingResource() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("original")
        let directory = fixture.root.appendingPathComponent("directory")
        try Data("original".utf8).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for (target, grouping) in [(file, "per-document"), (directory, "single")] {
            for policy in ["never", "always"] {
                let command = try ExportCommand.parse([
                    "--output", target.path, "--grouping", grouping, "--overwrite", policy,
                ])
                do {
                    _ = try command.execute(using: fixture.core())
                    Issue.record("Expected node-type failure")
                } catch let error as CLIError {
                    #expect(error.code == .writeSafety)
                    #expect(error.reason == (policy == "never" ? "output_exists" : "unsafe_output"))
                }
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        for count in [1, 100_001] {
            let result = ExportRunResult(destination: "/synthetic/export", disposition: .directory, documentCount: count, warningCount: 0)
            #expect(try JSONEncoder().encode(result).count < 200)
        }
    }

    @Test
    func pdfCommandsAndLegacyExportFlagsAreRejectedWithoutTouchingArtifacts() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("must-not-write.json")
        for arguments in [
            ["pdf", "list"],
            ["pdf", "highlights", "--book", "asset-a"],
            ["export", "--pdf", "pdf1_opaque", "--output", destination.path],
            ["export", "--source", "pdf", "--output", destination.path],
            ["export", "--source", "all", "--output", destination.path]
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: arguments, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(#""code":"usage_invalid""#))
            #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        }
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""

        var output: CLIOutput {
            CLIOutput(
                stdout: { [self] in stdout += $0 },
                stderr: { [self] in stderr += $0 }
            )
        }
    }

    private final class Fixture {
        enum Kind {
            case twoBooks
        }

        let root: URL
        let library: URL
        let annotations: URL
        let configuration: URL

        init(kind: Kind) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            configuration = root.appendingPathComponent("config.json")
            try Data("{\"historical_assets\":{}}".utf8).write(to: configuration)

            switch kind {
            case .twoBooks:
                try Self.createDatabase(library, sql: """
                CREATE TABLE ZBKLIBRARYASSET(
                  Z_PK INTEGER PRIMARY KEY,
                  ZASSETID TEXT,
                  ZTITLE TEXT,
                  ZAUTHOR TEXT,
                  ZCONTENTTYPE INTEGER
                );
                INSERT INTO ZBKLIBRARYASSET VALUES
                  (1,'asset-a','Book A','Author A',1),
                  (2,'asset-b','Book B','Author B',1);
                """)
                try Self.createDatabase(annotations, sql: Self.annotationSchema + """
                INSERT INTO ZAEANNOTATION VALUES
                  (1,'uuid-a','asset-a',0,0,1,1,10,20,'Quote A','Representative A','Note A','epubcfi(/6/2[a]!/4/2,:1,:2)',1,2,3,'Chapter A'),
                  (2,'uuid-b','asset-b',0,0,2,1,11,21,'Quote B','Representative B','Note B','epubcfi(/6/2[b]!/4/2,:1,:2)',4,5,6,'Chapter B');
                """)
            }
        }

        func core() throws -> AppleBooks {
            try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: configuration
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static let annotationSchema = """
        CREATE TABLE ZAEANNOTATION(
          Z_PK INTEGER PRIMARY KEY,
          ZANNOTATIONUUID TEXT,
          ZANNOTATIONASSETID TEXT,
          ZANNOTATIONDELETED INTEGER,
          ZANNOTATIONISUNDERLINE INTEGER,
          ZANNOTATIONSTYLE INTEGER,
          ZANNOTATIONTYPE INTEGER,
          ZANNOTATIONCREATIONDATE REAL,
          ZANNOTATIONMODIFICATIONDATE REAL,
          ZANNOTATIONSELECTEDTEXT TEXT,
          ZANNOTATIONREPRESENTATIVETEXT TEXT,
          ZANNOTATIONNOTE TEXT,
          ZANNOTATIONLOCATION TEXT,
          ZPLABSOLUTEPHYSICALLOCATION INTEGER,
          ZPLLOCATIONRANGESTART INTEGER,
          ZPLLOCATIONRANGEEND INTEGER,
          ZFUTUREPROOFING5 TEXT
        );
        """

        static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
                if let handle { sqlite3_close_v2(handle) }
                throw FixtureError.database
            }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }
    }

    private enum FixtureError: Error {
        case database
    }
}

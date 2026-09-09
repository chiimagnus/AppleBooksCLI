import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("ExportCommandTests")
struct ExportCommandTests {
    @Test
    func defaultsComeFromCoreExportOptions() throws {
        let command = try ExportCommand.parse(["--format", "json"])
        let request = try command.makeRequest()

        #expect(request.options == (try ExportOptions()))
        #expect(request.overwrite == .never)
        #expect(request.outputURL == nil)
        #expect(request.producesMultipleFiles == false)
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
            "--source", "all",
            "--kind", "bookmark",
            "--kind", "note",
            "--color", "yellow",
            "--color", "blue",
            "--underline",
            "--order", "reading",
            "--skip-first", "2",
            "--grouping", "per-book",
            "--include-epub-metadata",
            "--cover", "file",
            "--overwrite", "smart",
            "--output", output.path,
        ])
        let request = try command.makeRequest()

        #expect(request.options.source == .all)
        #expect(request.options.bookSelectors == [
            .assetID("asset-a"),
            .assetID("asset-b"),
            .localPK(11),
            .localPK(12),
        ])
        #expect(request.options.kinds == [.bookmark, .note])
        #expect(request.options.colors == [.yellow, .blue])
        #expect(request.options.underline == true)
        #expect(request.options.order == .reading)
        #expect(request.options.skipFirstPerBook == 2)
        #expect(request.options.grouping == .perBook)
        #expect(request.options.includeEPUBMetadata)
        #expect(request.options.cover == .file)
        #expect(request.overwrite == .smart)
        #expect(request.outputURL?.path == output.standardizedFileURL.path)
        #expect(request.producesMultipleFiles)
    }

    @Test
    func invalidOptionsFailBeforeDatabaseIO() throws {
        let missing = "/definitely/missing/applebooks.sqlite"
        let global = ["--library-db", missing, "--annotations-db", missing]

        let negativeSkip = try ExportCommand.parse([
            "--format", "json",
            "--skip-first", "-1",
        ] + global)
        #expect(throws: CLIError.usageInvalid("--skip-first must not be negative.")) {
            _ = try negativeSkip.makeRequest()
        }

        let noDirectory = try ExportCommand.parse([
            "--format", "json",
            "--grouping", "per-book",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try noDirectory.makeRequest() }

        let nonMarkdownFileCover = try ExportCommand.parse([
            "--format", "json",
            "--cover", "file",
            "--output", "/tmp/export.json",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try nonMarkdownFileCover.makeRequest() }
    }

    @Test
    func globalJSONIsRejectedInFavorOfExportFormatJSON() throws {
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["export", "--format", "json", "--json"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stderr.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(capture.stdout.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "`export` does not accept --json; use --format json.")
    }

    @Test
    func exactCurrentEPUBWithAllSourceDoesNotResolvePDFWorker() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("exact-epub.json")
        let command = try ExportCommand.parse([
            "--format", "json",
            "--book", "asset-a",
            "--source", "all",
            "--output", destination.path,
            "--library-db", fixture.library.path,
            "--annotations-db", fixture.annotations.path,
            "--config", fixture.configuration.path,
        ])
        var workerResolutionCount = 0

        let result = try command.execute(
            output: Capture().output,
            workerURLProvider: {
                workerResolutionCount += 1
                throw FixtureError.workerMustNotBeResolved
            }
        )

        #expect(workerResolutionCount == 0)
        #expect(result == .files(documentFileCount: 1, files: [destination]))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test
    func everySingleRendererWritesNativePayloadToStdoutWithoutWrapper() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let core = try fixture.core()
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        for format in ["json", "markdown"] {
            let command = try ExportCommand.parse(["--format", format])
            let capture = Capture()
            let result = try command.execute(using: core, output: capture.output, exportedAt: exportedAt)

            #expect(result == .stdout)
            #expect(capture.stdout.isEmpty == false)
            #expect(capture.stderr.isEmpty)
            switch format {
            case "json":
                let object = try JSONSerialization.jsonObject(with: Data(capture.stdout.utf8))
                #expect(object is [String: Any])
                #expect(capture.stdout.contains("\"groups\""))
            case "markdown":
                #expect(capture.stdout.contains("Quote A"))
            default:
                Issue.record("unexpected test format")
            }
        }
    }

    @Test
    func exactSingleFileUsesExportFileWriterAndNeverWritesPayloadToStdout() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("annotations.json")
        let command = try ExportCommand.parse([
            "--format", "json",
            "--output", destination.path,
        ])
        let capture = Capture()

        let result = try command.execute(using: fixture.core(), output: capture.output)

        #expect(result == .files(documentFileCount: 1, files: [destination]))
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.isEmpty)
        let data = try Data(contentsOf: destination)
        #expect(String(decoding: data, as: UTF8.self).contains("asset-a"))

        #expect(throws: CLIError.writeSafety("Output path is unsafe or already exists.")) {
            _ = try command.execute(using: fixture.core(), output: Capture().output)
        }
    }

    @Test
    func genericPerBookExportUsesWriterOwnedSafeDirectoryLayout() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("json-books", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "json",
            "--grouping", "per-book",
            "--output", directory.path,
        ])

        let result = try command.execute(using: fixture.core(), output: Capture().output)

        guard case let .files(documentFileCount, files) = result else {
            Issue.record("expected file result")
            return
        }
        #expect(documentFileCount == 2)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.deletingLastPathComponent() == directory.standardizedFileURL })
        #expect(Set(files.map(\.pathExtension)) == ["json"])
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

        private static func createDatabase(_ url: URL, sql: String) throws {
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
        case workerMustNotBeResolved
    }
}

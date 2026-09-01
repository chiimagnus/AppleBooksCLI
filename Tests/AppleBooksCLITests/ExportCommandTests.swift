import ArgumentParser
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("ExportCommandTests")
struct ExportCommandTests {
    @Test
    func defaultsComeFromCoreExportOptionsAndPlainProfile() throws {
        let command = try ExportCommand.parse(["--format", "json"])
        let request = try command.makeRequest()

        #expect(request.options == (try ExportOptions()))
        #expect(request.profile == .plain)
        #expect(request.overwrite == .never)
        #expect(request.outputURL == nil)
        #expect(request.producesMultipleFiles == false)
    }

    @Test
    func everySelectionAndObsidianSwitchMapsToExistingCoreOwners() throws {
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
            "--profile", "obsidian",
            "--overwrite", "smart",
            "--extended-frontmatter",
            "--body-metadata",
            "--tag", "research",
            "--tag", "books",
            "--chapter-headings",
            "--annotation-dates",
            "--annotation-styles",
            "--reading-progress",
            "--citation",
            "--author-pages",
            "--group-null-location-fragments",
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
        #expect(request.options.completeNotes == false)
        #expect(request.profile.syntax == .obsidian)
        #expect(request.profile.options.extendedFrontmatter)
        #expect(request.profile.options.bodyMetadata)
        #expect(request.profile.options.includeTags == false)
        #expect(request.profile.options.customTags == ["research", "books"])
        #expect(request.profile.options.chapterHeadings)
        #expect(request.profile.options.annotationDates)
        #expect(request.profile.options.annotationStyle)
        #expect(request.profile.options.readingProgress)
        #expect(request.profile.options.citation)
        #expect(request.profile.options.authorLinks)
        #expect(request.profile.options.authorPages)
        #expect(request.profile.options.groupConsecutiveNullLocationFragments)
        #expect(request.overwrite == .smart)
        #expect(request.outputURL?.path == output.standardizedFileURL.path)
        #expect(request.producesMultipleFiles)
    }

    @Test
    func completeNotesAndFormatSpecificInvalidCombinationsFailBeforeDatabaseIO() throws {
        let missing = "/definitely/missing/applebooks.sqlite"
        let global = ["--library-db", missing, "--annotations-db", missing]

        let filtered = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--kind", "highlight",
            "--kind", "note",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try filtered.makeRequest() }

        let incompatibleSource = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--source", "pdf",
        ] + global)
        #expect(throws: CLIError.usageInvalid("Export options conflict.")) {
            _ = try incompatibleSource.makeRequest()
        }

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

        let completeOverwrite = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--grouping", "per-book",
            "--overwrite", "smart",
            "--output", "/tmp/archive",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try completeOverwrite.makeRequest() }

        let nonMarkdownFileCover = try ExportCommand.parse([
            "--format", "html",
            "--cover", "file",
            "--output", "/tmp/export.html",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try nonMarkdownFileCover.makeRequest() }

        let plainExtras = try ExportCommand.parse([
            "--format", "markdown",
            "--tag", "ignored-if-allowed",
        ] + global)
        #expect(throws: ValidationError.self) { _ = try plainExtras.makeRequest() }
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
    func everySingleRendererWritesNativePayloadToStdoutWithoutWrapper() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let core = try fixture.core()
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000)

        for format in ["json", "csv", "markdown", "html"] {
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
            case "csv":
                #expect(capture.stdout.hasPrefix("\u{FEFF}"))
                #expect(capture.stdout.contains("asset-a"))
            case "markdown":
                #expect(capture.stdout.contains("Quote A"))
            case "html":
                #expect(capture.stdout.lowercased().contains("<!doctype html>"))
            default:
                Issue.record("unexpected test format")
            }
        }
    }

    @Test
    func exactSingleFileUsesExportFileWriterAndNeverWritesPayloadToStdout() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("annotations.csv")
        let command = try ExportCommand.parse([
            "--format", "csv",
            "--output", destination.path,
        ])
        let capture = Capture()

        let result = try command.execute(using: fixture.core(), output: capture.output)

        #expect(result == .files(documentFileCount: 1, files: [destination], warningCount: 0))
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.isEmpty)
        let data = try Data(contentsOf: destination)
        #expect(data.starts(with: [0xEF, 0xBB, 0xBF]))
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

        guard case let .files(documentFileCount, files, warningCount) = result else {
            Issue.record("expected file result")
            return
        }
        #expect(documentFileCount == 2)
        #expect(warningCount == 0)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.deletingLastPathComponent() == directory.standardizedFileURL })
        #expect(Set(files.map(\.pathExtension)) == ["json"])
    }

    @Test
    func authorPagesMakeSingleMarkdownAWriterOwnedMultiFileExport() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("obsidian", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "markdown",
            "--profile", "obsidian",
            "--author-pages",
            "--output", directory.path,
        ])

        let request = try command.makeRequest()
        #expect(request.options.grouping == .single)
        #expect(request.producesMultipleFiles)
        let result = try command.execute(using: fixture.core(), output: Capture().output)

        guard case let .files(documentFileCount, files, warningCount) = result else {
            Issue.record("expected file result")
            return
        }
        #expect(documentFileCount == 1)
        #expect(warningCount == 0)
        #expect(files.contains { $0.lastPathComponent == "apple-books-export.md" })
        #expect(files.contains { $0.path.contains("/Authors/") && $0.pathExtension == "md" })
        let book = try String(
            contentsOf: directory.appendingPathComponent("apple-books-export.md"),
            encoding: .utf8
        )
        #expect(book.contains("[[Authors/"))
    }

    @Test
    func completeNoteSafetyFailureIsTranslatedAndWritesNothing() throws {
        let fixture = try Fixture(kind: .unmappedNote)
        defer { fixture.remove() }
        let destination = fixture.root.appendingPathComponent("archive.json")
        let command = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--output", destination.path,
        ])

        #expect(throws: CLIError.writeSafety("Complete-note archive safety validation failed.")) {
            _ = try command.execute(using: fixture.core(), output: Capture().output)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }

    @Test
    func completePerBookArchivePublishesThroughStagingAndNeverMixesExistingDirectory() throws {
        let fixture = try Fixture(kind: .twoBooks)
        defer { fixture.remove() }
        let archive = fixture.root.appendingPathComponent("complete", isDirectory: true)
        let command = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--grouping", "per-book",
            "--output", archive.path,
        ])

        let result = try command.execute(using: fixture.core(), output: Capture().output)
        guard case let .files(documentFileCount, files, warningCount) = result else {
            Issue.record("expected file result")
            return
        }
        #expect(documentFileCount == 2)
        #expect(warningCount == 0)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.path.hasPrefix(archive.path + "/") })
        #expect(try stagingNames(in: fixture.root).isEmpty)

        let existing = fixture.root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let marker = existing.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let existingCommand = try ExportCommand.parse([
            "--format", "json",
            "--complete-notes",
            "--grouping", "per-book",
            "--output", existing.path,
        ])
        #expect(throws: CLIError.writeSafety("Output path is unsafe or already exists.")) {
            _ = try existingCommand.execute(using: fixture.core(), output: Capture().output)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
        #expect(try stagingNames(in: fixture.root).isEmpty)
    }

    private func stagingNames(in parent: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: parent.path).filter {
            $0.hasPrefix(".applebookscli-archive-") && $0.hasSuffix(".staging")
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
            case unmappedNote
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
            case .unmappedNote:
                try Self.createDatabase(library, sql: """
                CREATE TABLE ZBKLIBRARYASSET(
                  Z_PK INTEGER PRIMARY KEY,
                  ZASSETID TEXT,
                  ZTITLE TEXT,
                  ZAUTHOR TEXT,
                  ZCONTENTTYPE INTEGER
                );
                """)
                try Self.createDatabase(annotations, sql: Self.annotationSchema + """
                INSERT INTO ZAEANNOTATION VALUES
                  (1,'uuid-orphan','missing-asset',0,0,1,1,10,20,'Private Quote','Private Representative','Private Note',NULL,NULL,NULL,NULL,NULL);
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
    }
}

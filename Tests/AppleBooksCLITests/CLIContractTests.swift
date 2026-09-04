import AppKit
import Foundation
import PDFKit
import SQLite3
import Testing
@testable import AppleBooksCLI

@Suite("CLIContractTests")
struct CLIContractTests {
    @Test
    func processParseHelpAndVersionContractsDoNotDiscoverDatabases() throws {
        let harness = try ProcessHarness()
        defer { harness.remove() }

        let humanError = try harness.run(["books", "list", "--definitely-unknown"])
        #expect(humanError.status == CLIProcessExit.usageInvalid.rawValue)
        #expect(humanError.stdout.isEmpty)
        #expect(humanError.stderr.isEmpty == false)
        #expect(humanError.stderr.contains("definitely-unknown"))

        let jsonError = try harness.run(["books", "list", "--json", "--definitely-unknown"])
        #expect(jsonError.status == CLIProcessExit.usageInvalid.rawValue)
        #expect(jsonError.stderr.isEmpty)
        let envelope = try dictionary(jsonError.stdout)
        #expect(envelope["ok"] as? Bool == false)
        let error = try #require(envelope["error"] as? [String: Any])
        #expect(error["code"] as? String == "usage_invalid")

        let help = try harness.run(["--help"])
        #expect(help.status == 0)
        #expect(help.stderr.isEmpty)
        #expect(help.stdout.contains("USAGE:"))
        #expect(help.stdout.contains("export"))
        #expect(help.stdout.contains("backups"))

        let version = try harness.run(["--version"])
        #expect(version.status == 0)
        #expect(version.stderr.isEmpty)
        #expect(version.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "dev")
        #expect(FileManager.default.fileExists(atPath: harness.historyRoot.path) == false)
    }

    @Test
    func recordableCommandWhitelistIsExact() throws {
        let cases: [([String], String)] = [
            (["annotations", "update-note", "annotation-id", "--note", "note"], "annotations.update-note"),
            (["annotations", "delete", "annotation-id"], "annotations.delete"),
            (["collections", "create", "Shelf"], "collections.create"),
            (["collections", "rename", "collection-id", "--title", "Renamed"], "collections.rename"),
            (["collections", "delete", "collection-id"], "collections.delete"),
            (["collections", "add-book", "collection-id", "asset-id"], "collections.add-book"),
            (["collections", "remove-book", "collection-id", "asset-id"], "collections.remove-book"),
            (["backups", "restore", "library__20000101T000000Z__00000000-0000-4000-8000-000000000000.sqlite"], "backups.restore"),
            (["sync"], "sync"),
        ]

        for (arguments, operation) in cases {
            let command = try AppleBooksCLI.parseAsRoot(arguments)
            let recordable = try #require(command as? any OperationHistoryRecordable)
            #expect(recordable.historyOperation == operation)
        }

        for arguments in [
            ["books", "list"],
            ["export", "--format", "json"],
            ["backups", "list"],
        ] {
            let command = try AppleBooksCLI.parseAsRoot(arguments)
            #expect((command as? any OperationHistoryRecordable) == nil)
        }
    }

    @Test
    func processReadContractCoversDoctorBooksReadingContentAnnotationsAndCollections() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let doctor = try fixture.runJSON(["doctor"])
        #expect(doctor["libraryDatabaseReady"] as? Bool == true)
        #expect(doctor["annotationsDatabaseReady"] as? Bool == true)
        #expect(doctor["installedPDFWorkerReady"] as? Bool == true)

        let list = try fixture.runJSON(["books", "list", "--all"])
        #expect(list["total"] as? Int == 3)
        let listedBooks = try #require(list["items"] as? [[String: Any]])
        #expect(Set(listedBooks.compactMap { $0["assetID"] as? String }) == ["asset-a", "asset-b", "asset-pdf"])

        let get = try fixture.runJSON(["books", "get", "asset-a"])
        #expect(get["localPK"] as? Int == 1)
        #expect(get["assetID"] as? String == "asset-a")

        let search = try fixture.runJSON(["books", "search", "Book A"])
        #expect(search["total"] as? Int == 1)

        let inProgress = try fixture.runJSON(["reading", "in-progress"])
        let inProgressItems = try #require(inProgress["items"] as? [[String: Any]])
        #expect(inProgressItems.contains { $0["assetID"] as? String == "asset-a" })

        let stats = try fixture.runJSON(["stats"])
        #expect(stats["totalBooks"] as? Int == 3)
        #expect(stats["totalUserAnnotations"] as? Int == 3)

        let position = try fixture.runJSON(["reading", "position", "asset-a"])
        #expect(position["chapterID"] as? String == "shared")
        #expect(position["source"] as? String == "bookmarkToc")

        let status = try fixture.runJSON(["content", "status", "asset-a"])
        #expect(status["ready"] as? Bool == true)
        #expect(status["selectedSource"] as? String == "current")

        let metadata = try fixture.runJSON(["content", "metadata", "asset-a"])
        let epubMetadata = try #require(metadata["epub"] as? [String: Any])
        #expect(epubMetadata["title"] as? String == "Synthetic EPUB")
        #expect(epubMetadata["creator"] as? String == "Fixture Author")

        let located = try fixture.runJSON([
            "content", "locate", "asset-a", "epubcfi(/6/2[shared]!/4/2,:0,:5)",
        ])
        #expect(located["chapterID"] as? String == "shared")

        let chapter = try fixture.runJSON([
            "content", "chapter", "asset-a", "shared", "--max-chars", "12",
        ])
        #expect(chapter["chapterSelector"] as? String == "shared")
        #expect((chapter["content"] as? String)?.isEmpty == false)

        let context = try fixture.runJSON([
            "content", "context", "uuid-a", "--before", "8", "--after", "8",
        ])
        #expect(context["matchFound"] as? Bool == true)
        #expect(context["matched"] as? String == "First & 😀")

        let annotations = try fixture.runJSON(["annotations", "list", "--book", "asset-a"])
        let annotationItems = try #require(annotations["items"] as? [[String: Any]])
        #expect(Set(annotationItems.compactMap { $0["uuid"] as? String }) == ["uuid-a", "uuid-update"])

        let annotationSearch = try fixture.runJSON([
            "annotations", "search", "note alpha", "--field", "note",
        ])
        let searchItems = try #require(annotationSearch["items"] as? [[String: Any]])
        #expect(searchItems.count == 1)
        #expect(searchItems[0]["uuid"] as? String == "uuid-a")

        let annotationRange = try fixture.runJSON([
            "annotations", "range",
            "--after", "2001-01-01T00:01:30Z",
            "--before", "2001-01-01T00:02:30Z",
        ])
        #expect((annotationRange["items"] as? [[String: Any]])?.isEmpty == false)

        let collections = try fixture.runJSON(["collections", "list"])
        let collectionItems = try #require(collections["items"] as? [[String: Any]])
        #expect(collectionItems.contains { $0["collectionID"] as? String == ProcessFixture.shelfID })

        let collection = try fixture.runJSON(["collections", "get", ProcessFixture.shelfID])
        #expect(collection["localPK"] as? Int == 10)
        #expect(collection["sortKey"] as? Int == 10_000)
        #expect(collection["sortMode"] as? Int == 6)
        #expect(collection["lastModificationDate"] as? String != nil)
        #expect(collection["localModificationDate"] as? String != nil)

        let collectionSearch = try fixture.runJSON(["collections", "search", "Shelf"])
        #expect((collectionSearch["items"] as? [[String: Any]])?.count == 1)

        let collectionBooks = try fixture.runJSON(["collections", "books", ProcessFixture.shelfID])
        let memberItems = try #require(collectionBooks["items"] as? [[String: Any]])
        #expect(memberItems.map { $0["assetID"] as? String } == ["asset-a"])
    }

    @Test
    func processWritesUseGuardedBackupsAndRestoreOnlyScratchDatabases() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let create = try fixture.runJSON(["collections", "create", "Black Box Shelf"])
        #expect(create["committed"] as? Bool == true)
        #expect(create["changed"] as? Bool == true)
        let restoreHandle = try #require(create["backupHandle"] as? String)
        #expect(restoreHandle.hasPrefix("library__"))
        #expect(try fixture.scalarInt("SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Black Box Shelf'", database: fixture.library) == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.appendingPathComponent(restoreHandle).path))

        let note = "black box replacement"
        let update = try fixture.runJSON([
            "annotations", "update-note", "uuid-update", "--note", note,
        ])
        #expect(update["committed"] as? Bool == true)
        #expect(try fixture.scalarText("SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'", database: fixture.annotations) == note)
        let annotationHandle = try #require(update["backupHandle"] as? String)
        #expect(annotationHandle.hasPrefix("annotations__"))
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.appendingPathComponent(annotationHandle).path))

        let backups = try fixture.runJSON(["backups", "list"])
        let backupItems = try #require(backups["items"] as? [[String: Any]])
        #expect(backupItems.contains { $0["handle"] as? String == restoreHandle })
        #expect(backupItems.contains { $0["handle"] as? String == annotationHandle } == false)

        let restore = try fixture.runJSON(["backups", "restore", restoreHandle])
        #expect(restore["changed"] as? Bool == true)
        #expect(restore["verified"] as? Bool == true)
        #expect(restore["restoredFromHandle"] as? String == restoreHandle)
        let safetyHandle = try #require(restore["safetyBackupHandle"] as? String)
        #expect(safetyHandle != restoreHandle)
        #expect(FileManager.default.fileExists(atPath: fixture.backupRoot.appendingPathComponent(safetyHandle).path))
        #expect(try fixture.scalarInt("SELECT COUNT(*) FROM ZBKCOLLECTION WHERE ZTITLE='Black Box Shelf'", database: fixture.library) == 0)

        // ponytail: explicit DB overrides intentionally use a detached Books.app lifecycle; backup side effects prove
        // the executable still traverses the mutation coordinator instead of implementing direct CLI SQLite writes.
        #expect(fixture.harness.home.path.hasPrefix(fixture.harness.root.path + "/"))
        #expect(fixture.backupRoot.path.hasPrefix(fixture.harness.home.path))
    }

    @Test
    func processRecordableCommandsPersistArgumentsAndPresentedResults() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let createArguments = ["collections", "create", "History Shelf"] + fixture.globals + ["--json"]
        let create = try fixture.run(createArguments)
        #expect(create.status == 0)
        #expect(create.stderr.isEmpty)
        #expect(try dictionary(create.stdout)["committed"] as? Bool == true)

        let privateNote = "history private note"
        let updateArguments = [
            "annotations", "update-note", "uuid-update", "--note", privateNote,
        ] + fixture.globals + ["--json"]
        let update = try fixture.run(updateArguments)
        #expect(update.status == 0)
        #expect(update.stderr.isEmpty)
        #expect(update.stdout.contains(privateNote) == false)
        #expect(try fixture.scalarText(
            "SELECT ZANNOTATIONNOTE FROM ZAEANNOTATION WHERE ZANNOTATIONUUID='uuid-update'",
            database: fixture.annotations
        ) == privateNote)

        let noOpArguments = [
            "collections", "add-book", ProcessFixture.shelfID, "asset-a",
        ] + fixture.globals + ["--json"]
        let noOp = try fixture.run(noOpArguments)
        #expect(noOp.status == 0)
        #expect(try dictionary(noOp.stdout)["changed"] as? Bool == false)

        let jsonFailureArguments = [
            "collections", "rename", "missing-collection", "--title", "Nope",
        ] + fixture.globals + ["--json"]
        let jsonFailure = try fixture.run(jsonFailureArguments)
        #expect(jsonFailure.status == CLIProcessExit.notFound.rawValue)
        #expect(jsonFailure.stderr.isEmpty)
        let jsonEnvelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(jsonFailure.stdout.utf8))
        #expect(jsonEnvelope.error.code == .notFound)

        let humanFailureArguments = [
            "collections", "delete", "missing-collection",
        ] + fixture.globals
        let humanFailure = try fixture.run(humanFailureArguments)
        #expect(humanFailure.status == CLIProcessExit.notFound.rawValue)
        #expect(humanFailure.stdout.isEmpty)
        #expect(humanFailure.stderr.hasPrefix("Error:"))

        let history = try fixture.harness.historyRecords()
        #expect(history.count == 5)

        let createRecord = try #require(history.first { $0.operation == "collections.create" })
        #expect(createRecord.status == .success)
        #expect(createRecord.arguments == createArguments)
        #expect(createRecord.stdout == create.stdout)
        #expect(createRecord.stderr == create.stderr)

        let updateRecord = try #require(history.first { $0.operation == "annotations.update-note" })
        #expect(updateRecord.status == .success)
        #expect(updateRecord.arguments == updateArguments)
        #expect(updateRecord.arguments.contains(privateNote))
        #expect(updateRecord.stdout == update.stdout)

        let noOpRecord = try #require(history.first { $0.operation == "collections.add-book" })
        #expect(noOpRecord.status == .success)
        #expect(noOpRecord.arguments == noOpArguments)
        #expect(noOpRecord.stdout == noOp.stdout)

        let jsonFailureRecord = try #require(history.first { $0.operation == "collections.rename" })
        #expect(jsonFailureRecord.status == .failure)
        #expect(jsonFailureRecord.exitCode == CLIProcessExit.notFound.rawValue)
        #expect(jsonFailureRecord.stdout == jsonFailure.stdout)
        #expect(jsonFailureRecord.stderr == "")

        let humanFailureRecord = try #require(history.first { $0.operation == "collections.delete" })
        #expect(humanFailureRecord.status == .failure)
        #expect(humanFailureRecord.exitCode == CLIProcessExit.notFound.rawValue)
        #expect(humanFailureRecord.stdout == "")
        #expect(humanFailureRecord.stderr == humanFailure.stderr)
    }

    @Test
    func historyBeginFailureBlocksRecordableCommandBeforeDatabaseDiscovery() throws {
        let harness = try ProcessHarness()
        defer { harness.remove() }
        try FileManager.default.createDirectory(
            at: harness.historyRoot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not a directory".utf8).write(to: harness.historyRoot)

        let invocation = try harness.run(["sync", "--json"])
        #expect(invocation.status == CLIProcessExit.unavailable.rawValue)
        #expect(invocation.stderr.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(invocation.stdout.utf8))
        #expect(envelope.error.code == .unavailable)
        #expect(envelope.error.message == "Operation history is unavailable.")
    }

    @Test
    func historyCompletionFailurePreservesOriginalJsonOutcomeAndLeavesIncompleteEvidence() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-history-completion-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("history", isDirectory: true)
        let fixed = try #require(ISO8601DateFormatter().date(from: "2026-09-04T10:00:00Z"))
        let store = OperationHistoryStore(
            root: root,
            now: { fixed },
            timeZone: { TimeZone(secondsFromGMT: 0)! }
        )

        var stdout = ""
        var stderr = ""
        var sabotageError: Error?
        var sabotaged = false
        let output = CLIOutput(
            stdout: { text in
                stdout += text
                guard sabotaged == false else { return }
                sabotaged = true
                do {
                    let lock = root.appendingPathComponent(".lock")
                    try FileManager.default.removeItem(at: lock)
                    try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                } catch {
                    sabotageError = error
                }
            },
            stderr: { text in stderr += text }
        )

        let code = CLIEntrypoint.run(
            arguments: ["collections", "rename", "--title", "Nope", "--json"],
            output: output,
            historyStore: store
        )
        #expect(sabotageError == nil)
        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(stdout.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(stderr == "Warning: Operation history completion was not recorded.")

        let lock = root.appendingPathComponent(".lock")
        try FileManager.default.removeItem(at: lock)
        let records = try store.list()
        #expect(records.count == 1)
        #expect(records[0].operation == "collections.rename")
        #expect(records[0].status == .incomplete)
    }

    @Test
    func processPDFInventoryAndHighlightsUseRelativeInstalledWorker() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let inventory = try fixture.runJSON(["pdf", "list"])
        let items = try #require(inventory["items"] as? [[String: Any]])
        #expect(items.contains { item in
            guard let book = item["book"] as? [String: Any] else { return false }
            return book["assetID"] as? String == "asset-pdf"
        })

        let highlights = try fixture.runJSON(["pdf", "highlights", "--path", fixture.pdf.path])
        #expect(highlights["failedCount"] as? Int == 0)
        #expect(highlights["attemptedCount"] as? Int == 1)
        let documents = try #require(highlights["documents"] as? [[String: Any]])
        let first = try #require(documents.first)
        let rows = try #require(first["highlights"] as? [[String: Any]])
        #expect(rows.first?["note"] as? String == "black box pdf")
    }

    @Test
    func processExportKeepsNativePayloadsAndCompleteArchiveAtomic() throws {
        let fixture = try ProcessFixture()
        defer { fixture.remove() }

        let json = try fixture.run(["export", "--format", "json"] + fixture.globals)
        #expect(json.status == 0)
        #expect(json.stderr.isEmpty)
        let exportRoot = try dictionary(json.stdout)
        let groups = try #require(exportRoot["groups"] as? [[String: Any]])
        #expect(groups.count == 2)

        let markdown = try fixture.run(["export", "--format", "markdown"] + fixture.globals)
        #expect(markdown.status == 0)
        #expect(markdown.stderr.isEmpty)
        #expect(markdown.stdout.contains("First & 😀"))

        let archive = fixture.root.appendingPathComponent("complete-export", isDirectory: true)
        let complete = try fixture.run([
            "export", "--format", "json", "--complete-notes", "--grouping", "per-book",
            "--output", archive.path,
        ] + fixture.globals)
        #expect(complete.status == 0)
        #expect(complete.stdout.isEmpty)
        #expect(complete.stderr.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        #expect(files.allSatisfy { $0.pathExtension == "json" })
        let staging = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter {
            $0.hasPrefix(".applebookscli-archive-") && $0.hasSuffix(".staging")
        }
        #expect(staging.isEmpty)
    }
}

private func dictionary(_ text: String) throws -> [String: Any] {
    let value = try JSONSerialization.jsonObject(with: Data(text.utf8))
    guard let dictionary = value as? [String: Any] else { throw ContractFixtureError.invalidJSON }
    return dictionary
}

private struct ProcessInvocation {
    let status: Int32
    let stdout: String
    let stderr: String
}

private final class ProcessHarness {
    let root: URL
    let home: URL
    let cwd: URL
    let executable: URL

    var historyRoot: URL {
        home.appendingPathComponent("Library/Application Support/AppleBooksCLI/history", isDirectory: true)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-contract-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        cwd = root.appendingPathComponent("cwd", isDirectory: true)
        let install = root.appendingPathComponent("install", isDirectory: true)
        let bin = install.appendingPathComponent("bin", isDirectory: true)
        let libexec = install.appendingPathComponent("libexec/applebookscli", isDirectory: true)
        for directory in [home, cwd, bin, libexec] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let debug = repository.appendingPathComponent(".build/debug", isDirectory: true)
        let sourceCLI = debug.appendingPathComponent("applebookscli")
        let sourceWorker = debug.appendingPathComponent("applebookscli-pdf-worker")
        guard FileManager.default.isExecutableFile(atPath: sourceCLI.path),
              FileManager.default.isExecutableFile(atPath: sourceWorker.path) else {
            throw ContractFixtureError.missingExecutable
        }

        executable = bin.appendingPathComponent("applebookscli")
        try FileManager.default.copyItem(at: sourceCLI, to: executable)
        try FileManager.default.copyItem(
            at: sourceWorker,
            to: libexec.appendingPathComponent("applebookscli-pdf-worker")
        )
    }

    func run(_ arguments: [String]) throws -> ProcessInvocation {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = try stdout.fileHandleForReading.readToEnd() ?? Data()
        let err = try stderr.fileHandleForReading.readToEnd() ?? Data()
        return ProcessInvocation(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    func historyRecords() throws -> [OperationHistoryRecord] {
        try OperationHistoryStore(root: historyRoot).list()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ProcessFixture {
    static let shelfID = "550E8400-E29B-41D4-A716-446655440000"

    let harness: ProcessHarness
    let root: URL
    let library: URL
    let annotations: URL
    let config: URL
    let epub: URL
    let pdf: URL

    var backupRoot: URL {
        harness.home.appendingPathComponent("Library/Application Support/AppleBooksCLI/backups", isDirectory: true)
    }

    var globals: [String] {
        [
            "--library-db", library.path,
            "--annotations-db", annotations.path,
            "--config", config.path,
        ]
    }

    init() throws {
        harness = try ProcessHarness()
        root = harness.root.appendingPathComponent("fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        epub = root.appendingPathComponent("synthetic.epub", isDirectory: true)
        pdf = root.appendingPathComponent("synthetic.pdf")
        library = root.appendingPathComponent("library.sqlite")
        annotations = root.appendingPathComponent("annotations.sqlite")
        config = root.appendingPathComponent("config.json")

        try Self.makeEPUB(at: epub)
        try Self.makePDF(at: pdf)
        try Self.execute(library, sql: Self.librarySQL(epub: epub.path, pdf: pdf.path))
        try Self.execute(annotations, sql: Self.annotationSQL)
        try Data(#"{"historical_assets":{}}"#.utf8).write(to: config)
    }

    func run(_ arguments: [String]) throws -> ProcessInvocation {
        try harness.run(arguments)
    }

    func runJSON(_ arguments: [String]) throws -> [String: Any] {
        let invocation = try run(arguments + globals + ["--json"])
        #expect(invocation.status == 0)
        #expect(invocation.stderr.isEmpty)
        return try dictionary(invocation.stdout)
    }

    func scalarInt(_ sql: String, database: URL) throws -> Int64 {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else { throw ContractFixtureError.sqlite }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ContractFixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContractFixtureError.sqlite }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarText(_ sql: String, database: URL) throws -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else { throw ContractFixtureError.sqlite }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ContractFixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ContractFixtureError.sqlite }
        guard let raw = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: raw)
    }

    func remove() {
        harness.remove()
    }

    private static func makeEPUB(at root: URL) throws {
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let ops = root.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf"/></rootfiles>
        </container>
        """.utf8).write(to: meta.appendingPathComponent("container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
          <metadata>
            <dc:title>Synthetic EPUB</dc:title>
            <dc:creator>Fixture Author</dc:creator>
            <dc:language>en</dc:language>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="shared" href="shared.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="shared"/></spine>
        </package>
        """.utf8).write(to: ops.appendingPathComponent("package.opf"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol><li><a href="shared.xhtml">One</a></li></ol></nav></body>
        </html>
        """.utf8).write(to: ops.appendingPathComponent("nav.xhtml"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>Before First &amp; 😀 After.</p><p>Second section tail.</p></body></html>
        """.utf8).write(to: ops.appendingPathComponent("shared.xhtml"))
    }

    private static func makePDF(at url: URL) throws {
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 200, height: 200)).fill()
        image.unlockFocus()
        guard let page = PDFPage(image: image) else { throw ContractFixtureError.pdf }
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 20, y: 20, width: 100, height: 20),
            forType: .highlight,
            withProperties: nil
        )
        annotation.contents = "black box pdf"
        page.addAnnotation(annotation)
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: url) else { throw ContractFixtureError.pdf }
    }

    private static func execute(_ database: URL, sql: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(database.path, &handle) == SQLITE_OK, let handle else {
            throw ContractFixtureError.sqlite
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw ContractFixtureError.sqlite
        }
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private static func librarySQL(epub: String, pdf: String) -> String {
        """
        CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
        INSERT INTO Z_PRIMARYKEY VALUES
          ('BKCollection',7,20),
          ('BKCollectionMember',8,100);

        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT,
          ZBOOKDESCRIPTION TEXT,
          ZEPUBID TEXT,
          ZGENRE TEXT,
          ZGENRES BLOB,
          ZCOMMENTS TEXT,
          ZLANGUAGE TEXT,
          ZYEAR INTEGER,
          ZCONTENTTYPE INTEGER,
          ZPAGECOUNT INTEGER,
          ZPATH TEXT,
          ZFILESIZE INTEGER,
          ZCOVERURL TEXT,
          ZISFINISHED INTEGER,
          ZREADINGPROGRESS REAL,
          ZDURATION REAL,
          ZCREATIONDATE REAL,
          ZMODIFICATIONDATE REAL,
          ZDATEFINISHED REAL,
          ZLASTOPENDATE REAL,
          ZPURCHASEDATE REAL,
          ZRELEASEDATE REAL,
          ZISEXPLICIT INTEGER,
          ZISLOCKED INTEGER,
          ZISEPHEMERAL INTEGER,
          ZISHIDDEN INTEGER,
          ZISSAMPLE INTEGER,
          ZISSTOREAUDIOBOOK INTEGER,
          ZRATING REAL
        );
        INSERT INTO ZBKLIBRARYASSET
          (Z_PK,ZASSETID,ZTITLE,ZAUTHOR,ZGENRE,ZLANGUAGE,ZCONTENTTYPE,ZPATH,ZISFINISHED,ZREADINGPROGRESS,ZDATEFINISHED,ZLASTOPENDATE)
        VALUES
          (1,'asset-a','Book A','Author A','Fiction','en',1,'\(escaped(epub))',0,0.5,NULL,300),
          (2,'asset-b','Book B','Author B','History','en',1,'\(escaped(epub))',1,1.0,400,200),
          (3,'asset-pdf','PDF Book','PDF Author','Reference','en',3,'\(escaped(pdf))',0,0.0,NULL,100);

        CREATE TABLE ZBKCOLLECTION(
          Z_PK INTEGER PRIMARY KEY,
          Z_ENT INTEGER,
          Z_OPT INTEGER,
          ZDELETEDFLAG INTEGER,
          ZHIDDEN INTEGER,
          ZPLACEHOLDER INTEGER,
          ZSORTKEY INTEGER,
          ZSORTMODE INTEGER,
          ZVIEWMODE INTEGER,
          ZLASTMODIFICATION REAL,
          ZLOCALMODDATE REAL,
          ZCOLLECTIONID TEXT,
          ZDETAILS TEXT,
          ZTITLE TEXT
        );
        INSERT INTO ZBKCOLLECTION VALUES
          (10,7,1,0,0,0,10000,6,NULL,1,1,'\(shelfID)',NULL,'Shelf'),
          (20,7,1,0,0,0,20000,6,NULL,1,1,'550E8400-E29B-41D4-A716-446655440001',NULL,'Other');

        CREATE TABLE ZBKCOLLECTIONMEMBER(
          Z_PK INTEGER PRIMARY KEY,
          Z_ENT INTEGER,
          Z_OPT INTEGER,
          ZSORTKEY INTEGER,
          ZASSET INTEGER,
          ZCOLLECTION INTEGER,
          ZLOCALMODDATE REAL,
          ZASSETID TEXT,
          ZTEMPORARYASSETID TEXT
        );
        INSERT INTO ZBKCOLLECTIONMEMBER VALUES(100,8,1,10000,1,10,1,'asset-a',NULL);
        """
    }

    private static let annotationSQL = """
    CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
    INSERT INTO Z_PRIMARYKEY VALUES('AEAnnotation',11,4);
    CREATE TABLE ZAEANNOTATION(
      Z_PK INTEGER PRIMARY KEY,
      Z_ENT INTEGER,
      Z_OPT INTEGER,
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
      ZFUTUREPROOFING5 TEXT,
      ZFUTUREPROOFING6 TEXT
    );
    INSERT INTO ZAEANNOTATION VALUES
      (1,11,1,'uuid-a','asset-a',0,0,1,1,100,200,'First & 😀','First representative','note alpha','epubcfi(/6/2[shared]!/4/2,:0,:9)',1,2,3,'shared','200'),
      (2,11,1,'uuid-bookmark','asset-a',0,0,1,3,110,300,NULL,NULL,NULL,'epubcfi(/6/2[shared]!/4/2,:0,:0)',NULL,NULL,NULL,'shared','300'),
      (3,11,1,'uuid-b','asset-b',0,0,2,1,120,220,'Second section','Second representative','note beta','epubcfi(/6/2[shared]!/4/2,:0,:14)',4,5,6,'shared','220'),
      (4,11,1,'uuid-update','asset-a',0,0,3,1,130,230,'Update quote','Update representative','old note','epubcfi(/6/2[shared]!/4/2,:0,:6)',7,8,9,'shared','230');
    """
}

private enum ContractFixtureError: Error {
    case invalidJSON
    case missingExecutable
    case pdf
    case sqlite
}

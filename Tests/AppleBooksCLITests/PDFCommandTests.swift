import ArgumentParser
import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("PDFCommandTests")
struct PDFCommandTests {
    @Test
    func fakeWorkerSuccessPayloadMatchesPagedWorkerProtocol() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(
            path: fixture.explicit.path,
            mode: .agentSummary,
            limit: 20
        ))
        let process = Process()
        process.executableURL = fixture.worker
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: request)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let payload = try output.fileHandleForReading.readToEnd() ?? Data()
        let decoded = try PDFWorkerProtocol.decodeResponse(payload)
        #expect(decoded.version == 2)
        #expect(decoded.status == .success)
        #expect(decoded.mode == .agentSummary)
        #expect(decoded.summaryHighlights?.first?.note == "explicit")
        #expect(decoded.archiveHighlights == nil)
    }

    @Test
    func listUsesBoundedCursorIdentityOrderAndNeverPublishesAbsolutePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let core = try fixture.coreForInventory()

        var first = try PDFListCommand.parse(["--limit", "1"])
        let page1 = try first.execute(using: core)
        #expect(page1.items.count == 1)
        #expect(page1.items[0].bookAssetID == "123")
        #expect(page1.items[0].pdfSourceID == nil)
        #expect(page1.items[0].provenance == "library")
        #expect(page1.hasMore)
        let cursor1 = try #require(page1.nextCursor)

        first = try PDFListCommand.parse(["--limit", "1", "--cursor", cursor1])
        let page2 = try first.execute(using: core)
        #expect(page2.items.map(\.bookAssetID) == ["asset-pk"])
        #expect(page2.hasMore)
        let cursor2 = try #require(page2.nextCursor)

        let rest = try PDFListCommand.parse(["--limit", "100", "--cursor", cursor2]).execute(using: core)
        #expect(rest.items.allSatisfy { $0.bookAssetID == nil && $0.pdfSourceID != nil })
        #expect(rest.items.contains { $0.provenance == "fallback" && $0.title == "fallback" })
        #expect(rest.items.contains { $0.provenance == "library" && $0.title == "No ID PDF" })
        #expect(rest.hasMore == false)
        #expect(rest.nextCursor == nil)

        let json = try JSONEncoder().encode(PDFSourceListResult(
            items: page1.items + page2.items + rest.items,
            nextCursor: nil,
            hasMore: false
        ))
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains(fixture.root.path) == false)
        #expect(text.contains("filePath") == false)
    }

    @Test
    func fallbackSourceIDIsDirectlyConsumableByHighlights() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inventoryCore = try fixture.coreForInventory()
        let list = try PDFListCommand.parse(["--limit", "100"]).execute(using: inventoryCore)
        let fallback = try #require(list.items.first { $0.provenance == "fallback" })
        let sourceID = try #require(fallback.pdfSourceID)

        let result = try PDFHighlightsCommand.parse(["--pdf", sourceID]).execute(
            using: fixture.coreForInventory(worker: fixture.worker)
        )
        #expect(result.pdfSourceID == sourceID)
        #expect(result.bookAssetID == nil)
        #expect(result.items.first?.note == "fallback")
    }

    @Test
    func highlightsUseStableBookIdentityOpaqueCursorAndCompactSummaryOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let first = try PDFHighlightsCommand.parse(["--book", "123", "--limit", "1"] + fixture.arguments)
            .execute(workerURL: fixture.worker)
        #expect(first.bookAssetID == "123")
        #expect(first.pdfSourceID == nil)
        #expect(first.items.map(\.note) == ["asset-1"])
        #expect(first.items.first?.text == "private text")
        #expect(first.items.first?.textApproximate == true)
        #expect(first.items.first?.presentationColor?.name == "yellow")
        #expect(first.items.first?.presentationColor?.approximate == true)
        #expect(first.hasMore)
        let cursor = try #require(first.nextCursor)

        let second = try PDFHighlightsCommand.parse([
            "--book", "123", "--limit", "1", "--cursor", cursor,
        ] + fixture.arguments).execute(workerURL: fixture.worker)
        #expect(second.items.map(\.note) == ["asset-2"])
        #expect(second.hasMore == false)
        #expect(second.nextCursor == nil)

        let encoded = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
        for privateField in [
            "traversalIndex", "bounds", "quadrilateralPoints", "pdfKitRGBA",
            "textSource", "textUnavailableReason", "distance", "filePath", "provenance",
        ] {
            #expect(encoded.contains(privateField) == false)
        }
    }

    @Test
    func removedPathPKAndTimeoutSurfaceStayRejected() throws {
        let missing = "/definitely/missing/private.sqlite"
        let base = ["--library-db", missing, "--annotations-db", missing]
        for arguments in [
            ["--book-pk", "1"] + base,
            ["--path", "/tmp/private.pdf"] + base,
            ["--book", "123", "--timeout", "1"] + base,
        ] {
            let capture = Capture()
            let code = CLIEntrypoint.run(arguments: ["pdf", "highlights"] + arguments, output: capture.output)
            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            #expect(capture.stderr.contains(missing) == false)
        }

        let help = Capture()
        #expect(CLIEntrypoint.run(arguments: ["pdf", "highlights", "--help"], output: help.output) == 0)
        for present in ["--book", "--pdf", "--limit", "--cursor"] { #expect(help.stdout.contains(present)) }
        for removed in ["--book-pk", "--path", "--timeout", "--offset"] { #expect(help.stdout.contains(removed) == false) }
    }

    @Test
    func selectorAndPaginationValidationFailBeforeWorkerOrDatabaseIO() throws {
        let missing = "/definitely/missing/private.sqlite"
        let base = ["--library-db", missing, "--annotations-db", missing]
        let validID = "pdf1_" + String(repeating: "0", count: 64)

        for arguments in [
            base,
            ["--book", "123", "--pdf", validID] + base,
        ] {
            let command = try PDFHighlightsCommand.parse(arguments)
            #expect(throws: ValidationError.self) {
                _ = try command.execute(workerURL: URL(fileURLWithPath: "/missing-worker"))
            }
        }

        for invalidID in [
            "pdf1_" + String(repeating: "0", count: 63),
            "pdf1_" + String(repeating: "A", count: 64),
            String(repeating: "x", count: 4_096),
            "pdf1_" + String(repeating: "é", count: 64),
        ] {
            let command = try PDFHighlightsCommand.parse(["--pdf", invalidID] + base)
            do {
                _ = try command.execute(workerURL: URL(fileURLWithPath: "/missing-worker"))
                Issue.record("Expected invalid PDF source identity")
            } catch let error as CLIError {
                #expect(error.code == .usageInvalid)
                #expect(error.message.contains(missing) == false)
            }
        }

        for arguments in [
            ["--book", "123", "--limit", "0"] + base,
            ["--book", "123", "--limit", "101"] + base,
            ["--book", "123", "--cursor", "!"] + base,
        ] {
            let command = try PDFHighlightsCommand.parse(arguments)
            do {
                _ = try command.execute(workerURL: URL(fileURLWithPath: "/missing-worker"))
                Issue.record("Expected invalid pagination input")
            } catch let error as CLIError {
                #expect(error.code == .usageInvalid)
                #expect(error.message.contains(missing) == false)
            }
        }
    }

    @Test
    func listPaginationInputFailsBeforeDatabaseDiscovery() throws {
        let missing = "/definitely/missing/private.sqlite"
        let base = ["--library-db", missing, "--annotations-db", missing]
        for arguments in [
            ["--limit", "0"] + base,
            ["--limit", "101"] + base,
            ["--cursor", "!"] + base,
        ] {
            let command = try PDFListCommand.parse(arguments)
            do {
                _ = try command.execute()
                Issue.record("Expected invalid pagination input")
            } catch let error as CLIError {
                #expect(error.code == .usageInvalid)
                #expect(error.message.contains(missing) == false)
            }
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
        let root: URL
        let pdfRoot: URL
        let library: URL
        let annotations: URL
        let config: URL
        let current: URL
        let pkPDF: URL
        let noIDPDF: URL
        let fallback: URL
        let explicit: URL
        let timeoutPDF: URL
        let worker: URL

        var arguments: [String] {
            ["--library-db", library.path, "--annotations-db", annotations.path, "--config", config.path]
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            pdfRoot = root.appendingPathComponent("fallback", isDirectory: true)
            try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            current = root.appendingPathComponent("current.pdf")
            pkPDF = root.appendingPathComponent("pk.pdf")
            noIDPDF = root.appendingPathComponent("no-id.pdf")
            fallback = pdfRoot.appendingPathComponent("fallback.pdf")
            explicit = root.appendingPathComponent("explicit.pdf")
            timeoutPDF = root.appendingPathComponent("timeout.pdf")
            worker = root.appendingPathComponent("worker")
            for url in [current, pkPDF, noIDPDF, fallback, explicit, timeoutPDF] {
                try Data("pdf".utf8).write(to: url)
            }
            try Data("{}".utf8).write(to: config)
            try createDatabase(library, sql: """
                CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
                INSERT INTO ZBKLIBRARYASSET VALUES(1,'123','Asset PDF','A','\(sql(current.path))',3);
                INSERT INTO ZBKLIBRARYASSET VALUES(123,'asset-pk','PK PDF','B','\(sql(pkPDF.path))',3);
                INSERT INTO ZBKLIBRARYASSET VALUES(124,NULL,'No ID PDF','C','\(sql(noIDPDF.path))',3);
                """)
            try createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
            let script = """
            #!/bin/sh
            set -eu
            IFS= read -r request || true
            case "$request" in
              *timeout.pdf*) trap '' TERM; while :; do :; done ;;
              *current.pdf*) note=asset ;;
              *pk.pdf*) note=pk ;;
              *fallback.pdf*) note=fallback ;;
              *no-id.pdf*) note=noid ;;
              *) note=explicit ;;
            esac
            generation='pdfg2_0000000000000000000000000000000000000000000000000000000000000000'
            if printf '%s' "$request" | grep -q '"continuation"'; then
              printf '{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":2,"note":"%s-2","text":"private text","textApproximate":true,"presentationColor":{"name":"yellow","approximate":true},"truncatedFields":[]}],"hasMore":false,"generation":"%s"}' "$note" "$generation"
            elif printf '%s' "$request" | grep -q '"limit":1'; then
              printf '{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":2,"note":"%s-1","text":"private text","textApproximate":true,"presentationColor":{"name":"yellow","approximate":true},"truncatedFields":[]}],"nextTraversal":{"pageIndex":0,"annotationIndex":1},"hasMore":true,"generation":"%s"}' "$note" "$generation"
            else
              printf '{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":2,"note":"%s","text":"private text","textApproximate":true,"presentationColor":{"name":"yellow","approximate":true},"truncatedFields":[]}],"hasMore":false,"generation":"%s"}' "$note" "$generation"
            fi
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
        }

        func coreForInventory(worker: URL? = nil) throws -> AppleBooks {
            try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(database: library),
                annotationWriter: AnnotationWriter(database: annotations),
                pdfSourceResolver: PDFSourceResolver(fallbackRoot: pdfRoot),
                pdfWorkerClient: worker.map { PDFWorkerClient(workerURL: $0, timeout: 1) }
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
        }

        private func sql(_ value: String) -> String { value.replacingOccurrences(of: "'", with: "''") }
    }

    private enum FixtureError: Error { case database, permissions }
}

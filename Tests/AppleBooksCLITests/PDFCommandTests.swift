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
    func fakeWorkerSuccessPayloadMatchesWorkerProtocol() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(path: fixture.explicit.path))
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
        #expect(decoded.status == .success)
        #expect(decoded.highlights?.first?.note == "explicit")
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

        let command = try PDFHighlightsCommand.parse(["--pdf", sourceID])
        let result = try command.execute(using: fixture.coreForInventory(worker: fixture.worker))
        #expect(result.failures.isEmpty)
        let document = try #require(result.documents.first)
        #expect(document.source.pdfSourceID == sourceID)
        #expect(document.source.bookAssetID == nil)
        #expect(document.source.provenance == "fallback")
        #expect(document.highlights.first?.note == "fallback")
    }

    @Test
    func numericLookingBookSelectorNeverGuessesPK() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let byAsset = try PDFHighlightsCommand.parse(["--book", "123"] + fixture.arguments)
        let assetResult = try byAsset.execute(workerURL: fixture.worker)
        #expect(assetResult.failures.isEmpty)
        #expect(assetResult.documents.first?.highlights.first?.note == "asset")

        let byPK = try PDFHighlightsCommand.parse(["--book-pk", "123"] + fixture.arguments)
        let pkResult = try byPK.execute(workerURL: fixture.worker)
        #expect(pkResult.documents.first?.highlights.first?.note == "pk")
    }

    @Test
    func explicitPathRemainsCompatibilityOnlyAndDoesNotPublishThePath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try PDFHighlightsCommand.parse(["--path", fixture.explicit.path] + fixture.arguments)
        let result = try command.execute(workerURL: fixture.worker)
        #expect(result.failures.isEmpty)
        let document = try #require(result.documents.first)
        let highlight = try #require(document.highlights.first)

        #expect(document.source.provenance == "explicit")
        #expect(document.source.bookAssetID == nil)
        #expect(document.source.pdfSourceID == nil)
        #expect(highlight.page == 2)
        #expect(highlight.traversalIndex == 3)
        #expect(highlight.pdfKitRGBA == [1, 1, 0, 1])
        #expect(highlight.presentationColor?.color == "yellow")
        #expect(highlight.text == "private text")
        #expect(highlight.textSource == "quadSelection")
        #expect(highlight.textIsApproximate)

        let text = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
        #expect(text.contains(fixture.explicit.path) == false)
    }

    @Test
    func timeoutBecomesStructuredFailureAndDefaultHasOneCoreOwner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let defaultCommand = try PDFHighlightsCommand.parse(["--path", fixture.explicit.path] + fixture.arguments)
        #expect(defaultCommand.timeout == AppleBooks.defaultPDFWorkerTimeout)

        let timeoutCommand = try PDFHighlightsCommand.parse([
            "--path", fixture.timeoutPDF.path,
            "--timeout", "0.05",
        ] + fixture.arguments)
        let result = try timeoutCommand.execute(workerURL: fixture.worker)
        #expect(result.attemptedCount == 1)
        #expect(result.failedCount == 1)
        #expect(result.timeoutCount == 1)
        #expect(result.failures.first?.reason == "timeout")
    }

    @Test
    func selectorGrammarAndSourceIDValidationFailBeforeWorkerOrDatabaseIO() throws {
        let missing = "/definitely/missing/private.sqlite"
        let base = ["--library-db", missing, "--annotations-db", missing]
        let validID = "pdf1_" + String(repeating: "0", count: 64)

        for arguments in [
            base,
            ["--book", "123", "--pdf", validID] + base,
            ["--book-pk", "1", "--pdf", validID] + base,
            ["--pdf", validID, "--path", "/missing.pdf"] + base,
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

        let invalidTimeout = try PDFHighlightsCommand.parse(["--path", "/missing.pdf", "--timeout", "0"] + base)
        #expect(throws: ValidationError.self) {
            _ = try invalidTimeout.execute(workerURL: URL(fileURLWithPath: "/missing-worker"))
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
            if [ "${note-}" != "" ]; then
              printf '{"version":1,"status":"success","highlights":[{"page":2,"traversalIndex":3,"bounds":{"x":1,"y":2,"width":3,"height":4},"quadrilateralPoints":[],"note":"%s","pdfKitRGBA":[1,1,0,1],"presentationColor":{"color":"yellow","distance":0,"isApproximate":true},"text":"private text","textSource":"quadSelection","textIsApproximate":true}]}' "$note"
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

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
    func listPreservesLibraryAndFallbackProvenanceWithoutSyntheticAssetIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try PDFListCommand.parse([])
        let result = try command.execute(using: fixture.coreForInventory())

        let library = try #require(result.items.first { $0.filePath == fixture.current.path })
        #expect(library.provenance == "library")
        #expect(library.book?.assetID == "123")
        let fallback = try #require(result.items.first { $0.filePath == fixture.fallback.path })
        #expect(fallback.provenance == "fallback")
        #expect(fallback.book == nil)
        #expect(fallback.displayTitle == "fallback")
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
    func explicitPathKeepsExplicitProvenanceAndCanonicalPDFMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let command = try PDFHighlightsCommand.parse(["--path", fixture.explicit.path] + fixture.arguments)
        let result = try command.execute(workerURL: fixture.worker)
        #expect(result.failures.isEmpty)
        let document = try #require(result.documents.first)
        let highlight = try #require(document.highlights.first)

        #expect(document.source.provenance == "explicit")
        #expect(document.source.book == nil)
        #expect(highlight.page == 2)
        #expect(highlight.traversalIndex == 3)
        #expect(highlight.pdfKitRGBA == [1, 1, 0, 1])
        #expect(highlight.presentationColor?.color == "yellow")
        #expect(highlight.text == "private text")
        #expect(highlight.textSource == "quadSelection")
        #expect(highlight.textIsApproximate)
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
    func selectorConflictsAndInvalidTimeoutFailBeforeWorkerOrDatabaseIO() throws {
        let missing = "/definitely/missing/private.sqlite"
        let base = ["--library-db", missing, "--annotations-db", missing]
        let conflict = try PDFHighlightsCommand.parse(["--book", "123", "--path", "/missing.pdf"] + base)
        #expect(throws: ValidationError.self) { _ = try conflict.execute(workerURL: URL(fileURLWithPath: "/missing-worker")) }

        let invalidTimeout = try PDFHighlightsCommand.parse(["--path", "/missing.pdf", "--timeout", "0"] + base)
        #expect(throws: ValidationError.self) { _ = try invalidTimeout.execute(workerURL: URL(fileURLWithPath: "/missing-worker")) }
    }

    private final class Fixture {
        let root: URL
        let pdfRoot: URL
        let library: URL
        let annotations: URL
        let config: URL
        let current: URL
        let pkPDF: URL
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
            fallback = pdfRoot.appendingPathComponent("fallback.pdf")
            explicit = root.appendingPathComponent("explicit.pdf")
            timeoutPDF = root.appendingPathComponent("timeout.pdf")
            worker = root.appendingPathComponent("worker")
            for url in [current, pkPDF, fallback, explicit, timeoutPDF] { try Data("pdf".utf8).write(to: url) }
            try Data("{}".utf8).write(to: config)
            try createDatabase(library, sql: """
                CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZTITLE TEXT,ZAUTHOR TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);
                INSERT INTO ZBKLIBRARYASSET VALUES(1,'123','Asset PDF','A','\(sql(current.path))',3);
                INSERT INTO ZBKLIBRARYASSET VALUES(123,'asset-pk','PK PDF','B','\(sql(pkPDF.path))',3);
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
              *) note=explicit ;;
            esac
            if [ "${note-}" != "" ]; then
              printf '{"version":1,"status":"success","highlights":[{"page":2,"traversalIndex":3,"bounds":{"x":1,"y":2,"width":3,"height":4},"quadrilateralPoints":[],"note":"%s","pdfKitRGBA":[1,1,0,1],"presentationColor":{"color":"yellow","distance":0,"isApproximate":true},"text":"private text","textSource":"quadSelection","textIsApproximate":true}]}' "$note"
            fi
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
        }

        func coreForInventory() throws -> AppleBooks {
            try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                configurationFile: config,
                collectionWriter: CollectionWriter(database: library),
                annotationWriter: AnnotationWriter(database: annotations),
                pdfSourceResolver: PDFSourceResolver(fallbackRoot: pdfRoot)
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

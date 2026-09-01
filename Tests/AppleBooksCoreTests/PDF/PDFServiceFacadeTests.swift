import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PDFServiceFacadeTests")
struct PDFServiceFacadeTests {
    @Test
    func facadeExposesInventoryAndExtractionThroughSingleOwners() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = try fixture.pdf(name: "current.pdf")
        _ = try fixture.pdf(name: "fallback.pdf")
        try fixture.createDatabases(currentPDF: current)
        let worker = try fixture.worker()
        let core = try fixture.core(worker: worker)

        let sources = try core.pdfSources()
        #expect(sources.map(\.fileURL.lastPathComponent) == ["current.pdf", "fallback.pdf"])
        #expect(sources.first { $0.fileURL.lastPathComponent == "current.pdf" }?.book?.localPK == 1)
        #expect(sources.first { $0.fileURL.lastPathComponent == "fallback.pdf" }?.book == nil)

        let result = try core.pdfHighlights()
        #expect(result.attemptedCount == 2)
        #expect(result.succeededCount == 2)
        #expect(result.noHighlightsCount == 1)
        let currentResult = try #require(result.documents.first { $0.source.fileURL.lastPathComponent == "current.pdf" })
        #expect(currentResult.highlights.first?.note == "facade note")
        #expect(currentResult.highlights.first?.page == 1)
    }

    @Test
    func extractionRequiresExplicitWorkerInjection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = try fixture.pdf(name: "current.pdf")
        try fixture.createDatabases(currentPDF: current)
        let core = try fixture.core(worker: nil)

        #expect(try core.pdfSources().count == 1)
        #expect(throws: PDFHighlightFacadeError.workerUnavailable) {
            _ = try core.pdfHighlights()
        }
    }

    private final class Fixture {
        let root: URL
        let pdfRoot: URL
        let library: URL
        let annotations: URL
        let config: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            pdfRoot = root.appendingPathComponent("pdfs", isDirectory: true)
            library = root.appendingPathComponent("library.sqlite")
            annotations = root.appendingPathComponent("annotations.sqlite")
            config = root.appendingPathComponent("config.json")
            try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: config)
        }

        func pdf(name: String) throws -> URL {
            let url = pdfRoot.appendingPathComponent(name)
            try Data("synthetic".utf8).write(to: url)
            return url.standardizedFileURL.resolvingSymlinksInPath()
        }

        func createDatabases(currentPDF: URL) throws {
            try execute(
                library,
                """
                CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZCONTENTTYPE INTEGER,ZTITLE TEXT,ZPATH TEXT);
                INSERT INTO ZBKLIBRARYASSET VALUES(1,3,'Current PDF','\(sql(currentPDF.path))');
                """
            )
            try execute(annotations, "CREATE TABLE placeholder(value INTEGER);")
        }

        func core(worker: URL?) throws -> AppleBooks {
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

        func worker() throws -> URL {
            let url = root.appendingPathComponent("worker")
            let script = """
            #!/bin/sh
            set -eu
            IFS= read -r request || true
            case "$request" in
              *fallback.pdf*)
                printf '%s' '{"version":1,"status":"success","highlights":[]}'
                ;;
              *)
                printf '%s' '{"version":1,"status":"success","highlights":[{"page":1,"traversalIndex":0,"bounds":{"x":1,"y":2,"width":3,"height":4},"quadrilateralPoints":[],"note":"facade note","textIsApproximate":true}]}'
                ;;
            esac
            """
            try Data(script.utf8).write(to: url)
            guard chmod(url.path, 0o700) == 0 else { throw FixtureError.permissions }
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func execute(_ url: URL, _ statement: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
        }

        private func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }
    }

    private enum FixtureError: Error {
        case database
        case permissions
    }
}

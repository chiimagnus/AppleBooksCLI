import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PDFUpstreamConflictTests")
struct PDFUpstreamConflictTests {
    @Test
    func rawMarkerAbsenceNeverOverridesParserTruthAndFailuresStayDistinct() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let pdfRoot = root.appendingPathComponent("pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: pdfRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let markerNegative = pdfRoot.appendingPathComponent("marker-negative.pdf")
        let empty = pdfRoot.appendingPathComponent("valid-empty.pdf")
        let corrupt = pdfRoot.appendingPathComponent("corrupt.pdf")
        try Data("synthetic parser-owned fixture".utf8).write(to: markerNegative)
        try Data("synthetic empty fixture".utf8).write(to: empty)
        try Data("synthetic corrupt fixture".utf8).write(to: corrupt)
        #expect(String(decoding: try Data(contentsOf: markerNegative), as: UTF8.self).contains("/Highlight") == false)

        let library = root.appendingPathComponent("library.sqlite")
        try execute(library, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZCONTENTTYPE INTEGER,ZPATH TEXT);")

        let worker = root.appendingPathComponent("worker")
        let script = """
        #!/bin/sh
        set -eu
        IFS= read -r request || true
        case "$request" in
          *marker-negative.pdf*)
            printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"text":"parser truth","textSource":"boundsFallback","textIsApproximate":true}],"hasMore":false,"generation":"pdfg2_0000000000000000000000000000000000000000000000000000000000000000"}'
            ;;
          *valid-empty.pdf*)
            printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[],"hasMore":false,"generation":"pdfg2_0000000000000000000000000000000000000000000000000000000000000000"}'
            ;;
          *)
            printf '%s' '{"version":2,"status":"failure","errorCode":"unreadableDocument"}'
            ;;
        esac
        """
        try Data(script.utf8).write(to: worker)
        #expect(chmod(worker.path, 0o700) == 0)

        let service = PDFHighlightService(
            bookQueries: BookQueries(connection: try SQLiteConnection.readOnly(path: library.path)),
            sourceResolver: PDFSourceResolver(fallbackRoot: pdfRoot),
            workerClient: PDFWorkerClient(workerURL: worker, timeout: 1)
        )
        let result = service.readHighlights(sources: try service.inventory())
        #expect(result.attemptedCount == 3)
        #expect(result.succeededCount == 2)
        #expect(result.noHighlightsCount == 1)
        #expect(result.failedCount == 1)
        let markerResult = try #require(result.documents.first { $0.source.fileURL.lastPathComponent == "marker-negative.pdf" })
        #expect(markerResult.highlights.first?.text == "parser truth")
        let emptyResult = try #require(result.documents.first { $0.source.fileURL.lastPathComponent == "valid-empty.pdf" })
        #expect(emptyResult.highlights.isEmpty)
        let corruptFailure = try #require(result.failures.first { $0.source.fileURL.lastPathComponent == "corrupt.pdf" })
        #expect(corruptFailure.reason == .worker(.workerFailure(.unreadableDocument)))
    }

    private func execute(_ url: URL, _ statement: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw FixtureError.database }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw FixtureError.database }
    }

    private enum FixtureError: Error {
        case database
    }
}

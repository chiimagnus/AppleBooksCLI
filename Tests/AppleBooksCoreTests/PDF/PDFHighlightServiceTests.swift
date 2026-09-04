import Darwin
import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("PDFHighlightServiceTests")
struct PDFHighlightServiceTests {
    @Test
    func inventoryFlowsThroughWorkerAndContinuesAfterFailureAndTimeout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = try fixture.pdf(name: "current.pdf")
        _ = try fixture.pdf(name: "empty.pdf")
        _ = try fixture.pdf(name: "failure.pdf")
        _ = try fixture.pdf(name: "timeout.pdf")
        try fixture.database(currentPath: current.path)
        let worker = try fixture.worker()
        let service = try fixture.service(worker: worker, timeout: 2)

        let result = try service.readHighlights()

        #expect(result.attemptedCount == 4)
        #expect(result.succeededCount == 2)
        #expect(result.noHighlightsCount == 1)
        #expect(result.failedCount == 2)
        #expect(result.timeoutCount == 1)

        let currentDocument = try #require(result.documents.first { $0.source.fileURL.lastPathComponent == "current.pdf" })
        #expect(currentDocument.source.book?.localPK == 1)
        #expect(currentDocument.source.displayTitle == "Current PDF")
        let highlight = try #require(currentDocument.highlights.first)
        #expect(highlight.page == 2)
        #expect(highlight.note == "worker note")
        #expect(highlight.text == "worker text")
        #expect(highlight.textSource == .quadSelection)
        #expect(highlight.presentationColor?.color == .yellow)

        let emptyDocument = try #require(result.documents.first { $0.source.fileURL.lastPathComponent == "empty.pdf" })
        #expect(emptyDocument.source.book == nil)
        #expect(emptyDocument.highlights.isEmpty)

        let timeout = try #require(result.failures.first { $0.source.fileURL.lastPathComponent == "timeout.pdf" })
        #expect(timeout.reason == .timeout)
        let failure = try #require(result.failures.first { $0.source.fileURL.lastPathComponent == "failure.pdf" })
        #expect(failure.reason == .worker(.workerFailure(.unreadableDocument)))
    }

    @Test
    func repeatedServiceCallsAlwaysInvokeParserAndNeverUseHiddenCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = try fixture.pdf(name: "current.pdf")
        _ = try fixture.pdf(name: "empty.pdf")
        try fixture.database(currentPath: current.path)
        let worker = try fixture.worker()
        let service = try fixture.service(worker: worker, timeout: 1)

        #expect(try service.readHighlights().attemptedCount == 2)
        #expect(try service.readHighlights().attemptedCount == 2)

        let calls = try String(contentsOf: fixture.counter, encoding: .utf8)
        #expect(calls.count == 4)
    }

    private final class Fixture {
        let root: URL
        let fallbackRoot: URL
        let databaseURL: URL
        let counter: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            fallbackRoot = root.appendingPathComponent("pdfs", isDirectory: true)
            databaseURL = root.appendingPathComponent("library.sqlite")
            counter = root.appendingPathComponent("calls.txt")
            try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
        }

        func pdf(name: String) throws -> URL {
            let url = fallbackRoot.appendingPathComponent(name).standardizedFileURL
            try Data("synthetic".utf8).write(to: url)
            return url.resolvingSymlinksInPath()
        }

        func database(currentPath: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(databaseURL.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.database }
            defer { sqlite3_close_v2(handle) }
            let escaped = currentPath.replacingOccurrences(of: "'", with: "''")
            let sql = """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZCONTENTTYPE INTEGER,
              ZTITLE TEXT,
              ZPATH TEXT
            );
            INSERT INTO ZBKLIBRARYASSET VALUES(1,3,'Current PDF','\(escaped)');
            """
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.database
            }
        }

        func worker() throws -> URL {
            let worker = root.appendingPathComponent("fake-worker")
            let counterPath = shellQuote(counter.path)
            let script = """
            #!/bin/sh
            set -eu
            printf 'x' >> \(counterPath)
            IFS= read -r request || true
            case "$request" in
              *timeout.pdf*)
                trap '' TERM
                while :; do :; done
                ;;
              *failure.pdf*)
                printf '%s' '{"version":1,"status":"failure","errorCode":"unreadableDocument"}'
                ;;
              *empty.pdf*)
                printf '%s' '{"version":1,"status":"success","highlights":[]}'
                ;;
              *)
                printf '%s' '{"version":1,"status":"success","highlights":[{"page":2,"traversalIndex":3,"bounds":{"x":1,"y":2,"width":30,"height":4},"quadrilateralPoints":[],"note":"worker note","pdfKitRGBA":[1,1,0,1],"presentationColor":{"color":"yellow","distance":0,"isApproximate":true},"text":"worker text","textSource":"quadSelection","textIsApproximate":true}]}'
                ;;
            esac
            """
            try Data(script.utf8).write(to: worker)
            guard chmod(worker.path, 0o700) == 0 else { throw FixtureError.permissions }
            return worker
        }

        func service(worker: URL, timeout: TimeInterval) throws -> PDFHighlightService {
            let connection = try SQLiteConnection.readOnly(path: databaseURL.path)
            return PDFHighlightService(
                bookQueries: BookQueries(connection: connection),
                sourceResolver: PDFSourceResolver(fallbackRoot: fallbackRoot),
                workerClient: PDFWorkerClient(workerURL: worker, timeout: timeout, terminationGrace: 0.05)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private enum FixtureError: Error {
        case database
        case permissions
    }
}

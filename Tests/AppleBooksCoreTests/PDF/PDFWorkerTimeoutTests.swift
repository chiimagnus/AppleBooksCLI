import Darwin
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("PDFWorkerTimeoutTests")
struct PDFWorkerTimeoutTests {
    @Test
    func timeoutTerminatesAndReapsWorkerPID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let pidFile = fixture.root.appendingPathComponent("worker.pid")
        let worker = try fixture.script(
            """
            printf '%s' "$$" > \(shellQuote(pidFile.path))
            IFS= read -r request || true
            trap '' TERM
            while :; do :; done
            """,
            name: "slow-worker"
        )
        let client = PDFWorkerClient(workerURL: worker, timeout: 0.2, terminationGrace: 0.05)

        #expect(throws: PDFWorkerClientError.timedOut) {
            _ = try client.readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }

        let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(pid_t(pidText))
        errno = 0
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    @Test
    func outputLargerThanPipeCapacityDrainsWithoutDeadlock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chunk = String(repeating: "a", count: 4096)
        let chunkCount = 512
        let worker = try fixture.script(
            """
            IFS= read -r request || true
            printf '%s' '{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"note":"'
            chunk=\(shellQuote(chunk))
            i=0
            while [ "$i" -lt \(chunkCount) ]; do
              printf '%s' "$chunk"
              i=$((i + 1))
            done
            printf '%s' '","textIsApproximate":true}],"hasMore":false,"generation":"pdfg2_0000000000000000000000000000000000000000000000000000000000000000"}'
            """,
            name: "large-worker"
        )

        let page = try PDFWorkerClient(workerURL: worker, timeout: 5).readPage(
            fileURL: fixture.inputPDF,
            mode: .archive,
            limit: 1
        )
        #expect(page.archiveHighlights.count == 1)
        #expect(page.archiveHighlights[0].note?.count == chunk.count * chunkCount)
    }

    @Test
    func stdoutBeyondSafetyLimitTerminatesAtBoundedCapture() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chunk = String(repeating: "x", count: 4096)
        let worker = try fixture.script(
            """
            IFS= read -r request || true
            chunk=\(shellQuote(chunk))
            while :; do printf '%s' "$chunk"; done
            """,
            name: "oversize-stdout-worker"
        )
        let client = PDFWorkerClient(workerURL: worker, timeout: 20, terminationGrace: 0.05)

        #expect(throws: PDFWorkerClientError.stdoutLimitExceeded(capturedBytes: PDFWorkerClient.stdoutLimit)) {
            _ = try client.readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }
    }

    @Test
    func stderrBeyondSafetyLimitIsBoundedAndNeverReflected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let chunk = String(repeating: "s", count: 4096)
        let worker = try fixture.script(
            """
            IFS= read -r request || true
            chunk=\(shellQuote(chunk))
            while :; do printf '%s' "$chunk" >&2; done
            """,
            name: "oversize-stderr-worker"
        )
        let client = PDFWorkerClient(workerURL: worker, timeout: 5, terminationGrace: 0.05)

        #expect(throws: PDFWorkerClientError.stderrLimitExceeded(capturedBytes: PDFWorkerClient.stderrLimit)) {
            _ = try client.readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }
    }

    @Test
    func parallelClientsDoNotStarvePipeDrainers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worker = try fixture.script(
            "IFS= read -r request || true; printf '{\"version\":2,\"status\":\"success\",\"mode\":\"archive\",\"archiveHighlights\":[],\"hasMore\":false,\"generation\":\"pdfg2_0000000000000000000000000000000000000000000000000000000000000000\"}'",
            name: "parallel-worker"
        )
        let inputPDF = fixture.inputPDF

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try PDFWorkerClient(workerURL: worker, timeout: 2)
                        .readPage(fileURL: inputPDF, mode: .archive, limit: 1)
                        .archiveHighlights.count
                }
            }
            var completed = 0
            for try await count in group {
                #expect(count == 0)
                completed += 1
            }
            #expect(completed == 16)
        }
    }

    @Test
    func semanticValidationRejectsContradictoryAndUnsafePayloads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let generation = "pdfg2_" + String(repeating: "0", count: 64)
        let cases: [(PDFWorkerMode, String)] = [
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":1,"textApproximate":true,"truncatedFields":[]},{"page":2,"textApproximate":true,"truncatedFields":[]}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":0,"textApproximate":true,"truncatedFields":[]}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":1,"textApproximate":false,"truncatedFields":[]}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":1,"textApproximate":true,"presentationColor":{"name":"yellow","approximate":false},"truncatedFields":[]}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[{"page":1,"textApproximate":true,"presentationColor":{"name":"orange","approximate":true},"truncatedFields":[]}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.agentSummary, #"{"version":2,"status":"success","mode":"agentSummary","summaryHighlights":[],"hasMore":false,"generation":"\#(generation)","errorCode":"internalFailure"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":-1,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":-1,"height":1},"quadrilateralPoints":[],"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1e999,"height":1},"quadrilateralPoints":[],"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"pdfKitRGBA":[1,1,0],"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"presentationColor":{"color":"yellow","distance":-1,"isApproximate":true},"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"presentationColor":{"color":"orange","distance":0,"isApproximate":true},"textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
            (.archive, #"{"version":2,"status":"success","mode":"archive","archiveHighlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"text":"x","textSource":"unknown","textIsApproximate":true}],"hasMore":false,"generation":"\#(generation)"}"#),
        ]

        for (index, entry) in cases.enumerated() {
            let worker = try fixture.script(
                "IFS= read -r request || true; printf '%s' \(shellQuote(entry.1))",
                name: "malformed-semantic-\(index)"
            )
            #expect(throws: PDFWorkerClientError.malformedResponse) {
                _ = try PDFWorkerClient(workerURL: worker, timeout: 2).readPage(
                    fileURL: fixture.inputPDF,
                    mode: entry.0,
                    limit: 1
                )
            }
        }
    }

    @Test
    func malformedNonzeroSignalAndWorkerFailureStayStructured() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let malformed = try fixture.script("IFS= read -r request || true; printf 'not-json'", name: "malformed-worker")
        #expect(throws: PDFWorkerClientError.malformedResponse) {
            _ = try PDFWorkerClient(workerURL: malformed, timeout: 2).readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }

        let nonzero = try fixture.script("IFS= read -r request || true; exit 7", name: "nonzero-worker")
        #expect(throws: PDFWorkerClientError.nonzeroExit(7)) {
            _ = try PDFWorkerClient(workerURL: nonzero, timeout: 2).readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }

        let signaled = try fixture.script("IFS= read -r request || true; kill -SEGV $$", name: "signal-worker")
        #expect(throws: PDFWorkerClientError.signalTerminated(SIGSEGV)) {
            _ = try PDFWorkerClient(workerURL: signaled, timeout: 2).readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }

        let failure = try fixture.script(
            "IFS= read -r request || true; printf '{\"version\":2,\"status\":\"failure\",\"errorCode\":\"unreadableDocument\"}'",
            name: "failure-worker"
        )
        #expect(throws: PDFWorkerClientError.workerFailure(.unreadableDocument)) {
            _ = try PDFWorkerClient(workerURL: failure, timeout: 2).readPage(fileURL: fixture.inputPDF, mode: .archive, limit: 1)
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private final class Fixture {
        let root: URL
        let inputPDF: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            inputPDF = root.appendingPathComponent("input.pdf")
            try Data("synthetic".utf8).write(to: inputPDF)
        }

        func script(_ body: String, name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(to: url)
            #expect(chmod(url.path, 0o700) == 0)
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

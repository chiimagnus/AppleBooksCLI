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
            _ = try client.read(fileURL: fixture.inputPDF)
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
            printf '%s' '{"version":1,"status":"success","highlights":[{"page":1,"traversalIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1},"quadrilateralPoints":[],"note":"'
            chunk=\(shellQuote(chunk))
            i=0
            while [ "$i" -lt \(chunkCount) ]; do
              printf '%s' "$chunk"
              i=$((i + 1))
            done
            printf '%s' '","textIsApproximate":true}]}'
            """,
            name: "large-worker"
        )

        let highlights = try PDFWorkerClient(workerURL: worker, timeout: 5).read(fileURL: fixture.inputPDF)
        #expect(highlights.count == 1)
        #expect(highlights[0].note?.count == chunk.count * chunkCount)
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
            _ = try client.read(fileURL: fixture.inputPDF)
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
            _ = try client.read(fileURL: fixture.inputPDF)
        }
    }

    @Test
    func parallelClientsDoNotStarvePipeDrainers() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worker = try fixture.script(
            "IFS= read -r request || true; printf '{\"version\":1,\"status\":\"success\",\"highlights\":[]}'",
            name: "parallel-worker"
        )
        let inputPDF = fixture.inputPDF

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try PDFWorkerClient(workerURL: worker, timeout: 2).read(fileURL: inputPDF).count
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
    func malformedNonzeroSignalAndWorkerFailureStayStructured() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let malformed = try fixture.script("IFS= read -r request || true; printf 'not-json'", name: "malformed-worker")
        #expect(throws: PDFWorkerClientError.malformedResponse) {
            _ = try PDFWorkerClient(workerURL: malformed, timeout: 2).read(fileURL: fixture.inputPDF)
        }

        let nonzero = try fixture.script("IFS= read -r request || true; exit 7", name: "nonzero-worker")
        #expect(throws: PDFWorkerClientError.nonzeroExit(7)) {
            _ = try PDFWorkerClient(workerURL: nonzero, timeout: 2).read(fileURL: fixture.inputPDF)
        }

        let signaled = try fixture.script("IFS= read -r request || true; kill -SEGV $$", name: "signal-worker")
        #expect(throws: PDFWorkerClientError.signalTerminated(SIGSEGV)) {
            _ = try PDFWorkerClient(workerURL: signaled, timeout: 2).read(fileURL: fixture.inputPDF)
        }

        let failure = try fixture.script(
            "IFS= read -r request || true; printf '{\"version\":1,\"status\":\"failure\",\"errorCode\":\"unreadableDocument\"}'",
            name: "failure-worker"
        )
        #expect(throws: PDFWorkerClientError.workerFailure(.unreadableDocument)) {
            _ = try PDFWorkerClient(workerURL: failure, timeout: 2).read(fileURL: fixture.inputPDF)
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

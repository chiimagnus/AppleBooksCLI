import Darwin
import Foundation

public enum PDFWorkerClientError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case stdoutLimitExceeded(capturedBytes: Int)
    case stderrLimitExceeded(capturedBytes: Int)
    case pipeReadFailed
    case nonzeroExit(Int32)
    case signalTerminated(Int32)
    case malformedResponse
    case workerFailure(PDFWorkerErrorCode)
}

struct PDFWorkerClient {
    static let defaultTimeout: TimeInterval = 300
    // ponytail: 首版把单次 worker envelope 固定在 64 MiB；只有真实合法 PDF 证明会稳定超过它时才升级 streaming protocol。
    static let stdoutLimit = 64 * 1024 * 1024
    // ponytail: stderr 只是 sanitized lifecycle/error channel；若未来需要更多诊断，应改成结构化事件而不是放宽无界文本。
    static let stderrLimit = 256 * 1024

    let workerURL: URL
    let timeout: TimeInterval
    private let terminationGrace: TimeInterval

    init(
        workerURL: URL,
        timeout: TimeInterval = Self.defaultTimeout,
        terminationGrace: TimeInterval = 0.2
    ) {
        self.workerURL = workerURL
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    func read(fileURL: URL) throws -> [PDFWorkerHighlight] {
        let request: Data
        do {
            request = try PDFWorkerProtocol.encodeRequest(PDFWorkerRequest(path: fileURL.path))
        } catch {
            throw PDFWorkerClientError.malformedResponse
        }

        let process = Process()
        process.executableURL = workerURL
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PDFWorkerClientError.launchFailed
        }

        let stdoutCapture = BoundedPipeCapture(limit: Self.stdoutLimit)
        let stderrCapture = BoundedPipeCapture(limit: Self.stderrLimit)
        let drainGroup = DispatchGroup()
        PipeDrainer(handle: stdoutPipe.fileHandleForReading, capture: stdoutCapture).start(group: drainGroup)
        PipeDrainer(handle: stderrPipe.fileHandleForReading, capture: stderrCapture).start(group: drainGroup)

        stdinPipe.fileHandleForWriting.write(request)
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if stdoutCapture.didOverflow || stderrCapture.didOverflow {
                terminateAndReap(process)
                break
            }
            if Date() >= deadline {
                timedOut = true
                terminateAndReap(process)
                break
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        process.waitUntilExit()
        drainGroup.wait()

        if stdoutCapture.didOverflow {
            throw PDFWorkerClientError.stdoutLimitExceeded(capturedBytes: stdoutCapture.data.count)
        }
        if stderrCapture.didOverflow {
            throw PDFWorkerClientError.stderrLimitExceeded(capturedBytes: stderrCapture.data.count)
        }
        if timedOut {
            throw PDFWorkerClientError.timedOut
        }
        if stdoutCapture.readFailed || stderrCapture.readFailed {
            throw PDFWorkerClientError.pipeReadFailed
        }

        switch process.terminationReason {
        case .uncaughtSignal:
            throw PDFWorkerClientError.signalTerminated(process.terminationStatus)
        case .exit:
            guard process.terminationStatus == 0 else {
                throw PDFWorkerClientError.nonzeroExit(process.terminationStatus)
            }
        @unknown default:
            throw PDFWorkerClientError.nonzeroExit(process.terminationStatus)
        }

        let response: PDFWorkerResponse
        do {
            response = try PDFWorkerProtocol.decodeResponse(stdoutCapture.data)
        } catch {
            throw PDFWorkerClientError.malformedResponse
        }
        guard response.version == PDFWorkerProtocol.version else {
            throw PDFWorkerClientError.malformedResponse
        }
        switch response.status {
        case .success:
            guard response.errorCode == nil, let highlights = response.highlights else {
                throw PDFWorkerClientError.malformedResponse
            }
            return highlights
        case .failure:
            guard response.highlights == nil, let code = response.errorCode else {
                throw PDFWorkerClientError.malformedResponse
            }
            throw PDFWorkerClientError.workerFailure(code)
        }
    }

    private func terminateAndReap(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = kill(pid, SIGTERM)
        let graceDeadline = Date().addingTimeInterval(terminationGrace)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            _ = kill(pid, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class BoundedPipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var overflow = false
    private var failed = false

    init(limit: Int) {
        self.limit = limit
        storage.reserveCapacity(min(limit, 1024 * 1024))
    }

    var data: Data {
        lock.withLock { storage }
    }

    var didOverflow: Bool {
        lock.withLock { overflow }
    }

    var readFailed: Bool {
        lock.withLock { failed }
    }

    func append(_ chunk: Data) -> Bool {
        lock.withLock {
            guard overflow == false else { return false }
            let remaining = limit - storage.count
            if chunk.count > remaining {
                if remaining > 0 {
                    storage.append(chunk.prefix(remaining))
                }
                overflow = true
                return false
            }
            storage.append(chunk)
            return true
        }
    }

    func markReadFailed() {
        lock.withLock { failed = true }
    }
}

private final class PipeDrainer: @unchecked Sendable {
    private let handle: FileHandle
    private let capture: BoundedPipeCapture

    init(handle: FileHandle, capture: BoundedPipeCapture) {
        self.handle = handle
        self.capture = capture
    }

    func start(group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1024), chunk.isEmpty == false {
                    guard capture.append(chunk) else { break }
                }
            } catch {
                capture.markReadFailed()
            }
        }
    }
}

import AppKit
import Darwin
import Foundation

public enum BooksAppControllerError: Error, Equatable, Sendable {
    case terminateRejected
    case terminateTimedOut
    case applicationUnavailable
    case launchFailed
}

struct BooksAppController {
    static let bundleIdentifier = "com.apple.iBooksX"

    private let isRunningAction: () -> Bool
    private let terminateAction: () -> Bool
    private let launchAction: () throws -> Void
    private let runningProcessIDsAction: () -> [pid_t]
    private let isProcessAliveAction: (pid_t) -> Bool
    private let sleepAction: (TimeInterval) -> Void
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Bool,
        launch: @escaping () throws -> Void,
        runningProcessIDs: @escaping () -> [pid_t] = { [] },
        isProcessAlive: @escaping (pid_t) -> Bool = { _ in false },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        // ponytail: Books may spend tens of seconds flushing state before it terminates; keep writes fail-closed for up to one minute. Increase only if measured shutdowns exceed this bound.
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.05
    ) {
        isRunningAction = isRunning
        terminateAction = terminate
        launchAction = launch
        runningProcessIDsAction = runningProcessIDs
        isProcessAliveAction = isProcessAlive
        sleepAction = sleep
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    static var live: BooksAppController {
        BooksAppController(
            isRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty == false
            },
            terminate: {
                let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                return applications.allSatisfy { $0.terminate() }
            },
            launch: {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                    throw BooksAppControllerError.applicationUnavailable
                }
                guard NSWorkspace.shared.open(url) else {
                    throw BooksAppControllerError.launchFailed
                }
            },
            runningProcessIDs: {
                NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).map(\.processIdentifier)
            },
            isProcessAlive: { pid in
                errno = 0
                return kill(pid, 0) == 0 || errno == EPERM
            }
        )
    }

    static var detached: BooksAppController {
        BooksAppController(
            isRunning: { false },
            terminate: { true },
            launch: {}
        )
    }

    func isRunning() -> Bool {
        isRunningAction()
    }

    func terminateAndWait() throws {
        guard isRunning() else { return }
        let processIDs = runningProcessIDsAction()
        guard terminateAction() else { throw BooksAppControllerError.terminateRejected }

        let deadline = Date().addingTimeInterval(timeout)
        while isRunning() || processIDs.contains(where: isProcessAliveAction) {
            guard Date() < deadline else { throw BooksAppControllerError.terminateTimedOut }
            sleepAction(pollInterval)
        }
    }

    func launch() throws {
        try launchAction()
    }
}

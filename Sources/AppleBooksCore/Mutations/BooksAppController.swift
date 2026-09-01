import AppKit
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
    private let sleepAction: (TimeInterval) -> Void
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Bool,
        launch: @escaping () throws -> Void,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        timeout: TimeInterval = 3,
        pollInterval: TimeInterval = 0.05
    ) {
        isRunningAction = isRunning
        terminateAction = terminate
        launchAction = launch
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
        guard terminateAction() else { throw BooksAppControllerError.terminateRejected }

        let deadline = Date().addingTimeInterval(timeout)
        while isRunning() {
            guard Date() < deadline else { throw BooksAppControllerError.terminateTimedOut }
            sleepAction(pollInterval)
        }
    }

    func launch() throws {
        try launchAction()
    }
}

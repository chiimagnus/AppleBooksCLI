import AppKit
import Darwin
import Foundation

public enum BooksAppControllerError: Error, Equatable, Sendable {
    case terminateRejected
    case terminateTimedOut
    case applicationUnavailable
    case launchFailed
}

enum BooksAppState: Equatable, Sendable {
    case closed
    case background
    case frontmost
}

struct BooksAppController {
    static let bundleIdentifier = "com.apple.iBooksX"

    private let isRunningAction: () -> Bool
    private let isFrontmostAction: () -> Bool
    private let terminateAction: () -> Bool
    private let launchAction: () throws -> Void
    private let launchWithoutActivationAction: () throws -> Void
    private let activateAction: () throws -> Void
    private let openURLAction: (URL) -> Bool
    private let runningProcessIDsAction: () -> [pid_t]
    private let isProcessAliveAction: (pid_t) -> Bool
    private let sleepAction: (TimeInterval) -> Void
    private let timeout: TimeInterval
    private let pollInterval: TimeInterval

    init(
        isRunning: @escaping () -> Bool,
        terminate: @escaping () -> Bool,
        launch: @escaping () throws -> Void,
        isFrontmost: @escaping () -> Bool = { false },
        launchWithoutActivation: (() throws -> Void)? = nil,
        activate: (() throws -> Void)? = nil,
        openURL: @escaping (URL) -> Bool = { _ in false },
        runningProcessIDs: @escaping () -> [pid_t] = { [] },
        isProcessAlive: @escaping (pid_t) -> Bool = { _ in false },
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        // ponytail: Books may spend tens of seconds flushing state before it terminates; keep writes fail-closed for up to one minute. Increase only if measured shutdowns exceed this bound.
        timeout: TimeInterval = 60,
        pollInterval: TimeInterval = 0.05
    ) {
        isRunningAction = isRunning
        isFrontmostAction = isFrontmost
        terminateAction = terminate
        launchAction = launch
        launchWithoutActivationAction = launchWithoutActivation ?? launch
        activateAction = activate ?? launch
        openURLAction = openURL
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
            isFrontmost: {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier
            },
            launchWithoutActivation: {
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
                    throw BooksAppControllerError.applicationUnavailable
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = false
                configuration.promptsUserIfNeeded = false
                NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
            },
            activate: {
                guard let application = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
                    throw BooksAppControllerError.applicationUnavailable
                }
                guard application.activate() else {
                    throw BooksAppControllerError.launchFailed
                }
            },
            openURL: { NSWorkspace.shared.open($0) },
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

    func state() -> BooksAppState {
        guard isRunning() else { return .closed }
        return isFrontmostAction() ? .frontmost : .background
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

    func launchWithoutActivationAndWait() throws {
        try launchWithoutActivationAction()
        try waitUntil(isRunningAction)
    }

    func open(_ url: URL) -> Bool {
        openURLAction(url)
    }

    func restore(_ state: BooksAppState) throws {
        switch state {
        case .closed:
            if isRunning() {
                try terminateAndWait()
            }
        case .background:
            if isRunning() == false {
                try launchWithoutActivationAndWait()
            }
        case .frontmost:
            if isRunning() == false {
                try launch()
                try waitUntil(isRunningAction)
            }
            guard isFrontmostAction() == false else { return }
            try activateAction()
            try waitUntil(isFrontmostAction)
        }
    }

    private func waitUntil(_ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            guard Date() < deadline else { throw BooksAppControllerError.launchFailed }
            sleepAction(pollInterval)
        }
    }
}

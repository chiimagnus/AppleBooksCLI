import Testing
@testable import AppleBooksCore

@Suite("BooksAppControllerTests")
struct BooksAppControllerTests {
    @Test
    func closedApplicationNeedsNoTerminateOrSleep() throws {
        var calls: [String] = []
        let controller = BooksAppController(
            isRunning: { calls.append("isRunning"); return false },
            terminate: { calls.append("terminate"); return true },
            launch: { calls.append("launch") },
            sleep: { _ in calls.append("sleep") }
        )

        try controller.terminateAndWait()
        #expect(calls == ["isRunning"])
    }

    @Test
    func runningApplicationTerminatesAndPollsUntilStopped() throws {
        var running = true
        var calls: [String] = []
        let controller = BooksAppController(
            isRunning: { calls.append("isRunning"); return running },
            terminate: { calls.append("terminate"); return true },
            launch: { calls.append("launch") },
            sleep: { _ in calls.append("sleep"); running = false },
            timeout: 3,
            pollInterval: 0.01
        )

        try controller.terminateAndWait()
        #expect(calls == ["isRunning", "terminate", "isRunning", "sleep", "isRunning"])
    }

    @Test
    func terminationWaitsForCapturedProcessAfterBundleInventoryDropsIt() throws {
        var bundleRunning = true
        var processAlive = true
        var sleepCount = 0
        let controller = BooksAppController(
            isRunning: { bundleRunning },
            terminate: { true },
            launch: {},
            runningProcessIDs: { [4242] },
            isProcessAlive: { pid in
                #expect(pid == 4242)
                return processAlive
            },
            sleep: { _ in
                sleepCount += 1
                if sleepCount == 1 {
                    bundleRunning = false
                } else {
                    processAlive = false
                }
            },
            timeout: 3,
            pollInterval: 0.01
        )

        try controller.terminateAndWait()
        #expect(sleepCount == 2)
        #expect(bundleRunning == false)
        #expect(processAlive == false)
    }

    @Test
    func terminateFailureAndTimeoutAreStructured() throws {
        let rejected = BooksAppController(
            isRunning: { true },
            terminate: { false },
            launch: {},
            sleep: { _ in }
        )
        #expect(throws: BooksAppControllerError.terminateRejected) {
            try rejected.terminateAndWait()
        }

        let timedOut = BooksAppController(
            isRunning: { true },
            terminate: { true },
            launch: {},
            sleep: { _ in },
            timeout: 0
        )
        #expect(throws: BooksAppControllerError.terminateTimedOut) {
            try timedOut.terminateAndWait()
        }
    }

    @Test
    func launchOnlyExecutesInjectedLaunchAction() throws {
        var calls: [String] = []
        let controller = BooksAppController(
            isRunning: { calls.append("isRunning"); return false },
            terminate: { calls.append("terminate"); return true },
            launch: { calls.append("launch") }
        )

        try controller.launch()
        #expect(calls == ["launch"])
        #expect(BooksAppController.bundleIdentifier == "com.apple.iBooksX")
    }

    @Test
    func stateDistinguishesClosedBackgroundAndFrontmost() {
        var running = false
        var frontmost = false
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { true },
            launch: {},
            isFrontmost: { frontmost }
        )

        #expect(controller.state() == .closed)
        running = true
        #expect(controller.state() == .background)
        frontmost = true
        #expect(controller.state() == .frontmost)
    }

    @Test
    func backgroundRestoreUsesNonActivatingLaunchAndWaitsForRunningState() throws {
        var running = false
        var frontmost = false
        var calls: [String] = []
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { true },
            launch: {
                calls.append("launch")
                running = true
                frontmost = true
            },
            isFrontmost: { frontmost },
            launchWithoutActivation: {
                calls.append("launchWithoutActivation")
                running = true
            },
            activate: {
                calls.append("activate")
                frontmost = true
            }
        )

        try controller.restore(.background)
        #expect(calls == ["launchWithoutActivation"])
        #expect(controller.state() == .background)
    }

    @Test
    func frontmostRestoreLaunchesThenActivatesAndVerifiesFrontmostState() throws {
        var running = false
        var frontmost = false
        var calls: [String] = []
        let controller = BooksAppController(
            isRunning: { running },
            terminate: { true },
            launch: {
                calls.append("launch")
                running = true
            },
            isFrontmost: { frontmost },
            activate: {
                calls.append("activate")
                frontmost = true
            }
        )

        try controller.restore(.frontmost)
        #expect(calls == ["launch", "activate"])
        #expect(controller.state() == .frontmost)
    }

    @Test
    func nonActivatingLaunchAndFrontmostVerificationAreBounded() throws {
        let launchTimedOut = BooksAppController(
            isRunning: { false },
            terminate: { true },
            launch: {},
            launchWithoutActivation: {},
            sleep: { _ in },
            timeout: 0
        )
        #expect(throws: BooksAppControllerError.launchFailed) {
            try launchTimedOut.launchWithoutActivationAndWait()
        }

        let activationTimedOut = BooksAppController(
            isRunning: { true },
            terminate: { true },
            launch: {},
            isFrontmost: { false },
            activate: {},
            sleep: { _ in },
            timeout: 0
        )
        #expect(throws: BooksAppControllerError.launchFailed) {
            try activationTimedOut.restore(.frontmost)
        }
    }
}

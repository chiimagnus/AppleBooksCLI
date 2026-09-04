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
}

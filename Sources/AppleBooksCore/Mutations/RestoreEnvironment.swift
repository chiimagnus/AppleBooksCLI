import AppKit
import SQLite3

func isBooksAppRunning() -> Bool {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iBooksX").isEmpty == false
}

struct RestoreEnvironment {
    let booksIsRunning: () -> Bool
    let pageCount: Int32
    let failAfterSteps: Int?

    static var live: RestoreEnvironment {
        RestoreEnvironment(
            booksIsRunning: isBooksAppRunning,
            pageCount: -1,
            failAfterSteps: nil
        )
    }
}

import AppKit
import SQLite3

struct RestoreEnvironment {
    let booksIsRunning: () -> Bool
    let pageCount: Int32
    let failAfterSteps: Int?

    static var live: RestoreEnvironment {
        RestoreEnvironment(
            booksIsRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iBooksX").isEmpty == false
            },
            pageCount: -1,
            failAfterSteps: nil
        )
    }
}

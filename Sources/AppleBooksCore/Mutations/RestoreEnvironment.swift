import SQLite3

struct RestoreEnvironment {
    let booksIsRunning: () -> Bool
    let pageCount: Int32
    let failAfterSteps: Int?

    static var live: RestoreEnvironment {
        let controller = BooksAppController.live
        return RestoreEnvironment(
            booksIsRunning: controller.isRunning,
            pageCount: -1,
            failAfterSteps: nil
        )
    }
}

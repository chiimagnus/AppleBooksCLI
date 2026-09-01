import AppleBooksCore
import ArgumentParser

struct StatsCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show canonical Apple Books library and annotation statistics."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let result = try CLIOperation.run {
            StatsResult(try CLIContext(global: global).makeAppleBooks().libraryStats())
        }
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct StatsResult: Codable, Equatable, Sendable {
    let totalBooks: Int
    let finishedBooks: Int
    let inProgressBooks: Int
    let unstartedBooks: Int
    let totalUserAnnotations: Int
    let orphanUserAnnotations: Int
    let topAnnotatedBooks: [BookResult]

    init(_ stats: LibraryStats) {
        totalBooks = stats.totalBooks
        finishedBooks = stats.finishedBooks
        inProgressBooks = stats.inProgressBooks
        unstartedBooks = stats.unstartedBooks
        totalUserAnnotations = stats.totalUserAnnotations
        orphanUserAnnotations = stats.orphanUserAnnotations
        topAnnotatedBooks = stats.topAnnotatedBooks.map { BookResult(overview: $0) }
    }

    var humanDescription: String {
        [
            "books: \(totalBooks)",
            "finished: \(finishedBooks)",
            "in progress: \(inProgressBooks)",
            "unstarted: \(unstartedBooks)",
            "user annotations: \(totalUserAnnotations)",
            "orphan annotations: \(orphanUserAnnotations)",
        ].joined(separator: "\n")
    }
}

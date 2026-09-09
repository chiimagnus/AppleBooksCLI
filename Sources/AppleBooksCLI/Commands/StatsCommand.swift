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
            StatsResult(try CLIContext(global: global).makeAppleBooks(dependencies: [.libraryRead, .annotationsRead, .configuration]).libraryStats())
        }
        try output.writeJSON(result)
    }
}

struct TopAnnotatedBookResult: Codable, Equatable, Sendable {
    let assetID: String?
    let localPK: Int64?
    let annotationCount: Int

    init(_ summary: TopAnnotatedBookSummary) {
        if PublicStableTokenPolicy.isEligible(summary.assetID) {
            assetID = summary.assetID
            localPK = nil
        } else {
            assetID = nil
            localPK = LocalPKPolicy.isEligible(summary.localPK) ? summary.localPK : nil
        }
        annotationCount = summary.annotationCount
    }
}

struct StatsResult: Codable, Equatable, Sendable {
    let totalBooks: Int
    let finishedBooks: Int
    let inProgressBooks: Int
    let unstartedBooks: Int
    let totalUserAnnotations: Int
    let historicalAnnotationCount: Int
    let unmappedAnnotationCount: Int
    let ambiguousAnnotationCount: Int
    let identityUnavailableAnnotationCount: Int
    let topAnnotatedBooks: [TopAnnotatedBookResult]

    init(_ stats: LibraryStats) {
        totalBooks = stats.totalBooks
        finishedBooks = stats.finishedBooks
        inProgressBooks = stats.inProgressBooks
        unstartedBooks = stats.unstartedBooks
        totalUserAnnotations = stats.totalUserAnnotations
        historicalAnnotationCount = stats.historicalAnnotationCount
        unmappedAnnotationCount = stats.unmappedAnnotationCount
        ambiguousAnnotationCount = stats.ambiguousAnnotationCount
        identityUnavailableAnnotationCount = stats.identityUnavailableAnnotationCount
        topAnnotatedBooks = stats.topAnnotatedBookSummaries.map(TopAnnotatedBookResult.init)
    }
}

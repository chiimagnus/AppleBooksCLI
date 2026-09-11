import AppleBooksCore
import ArgumentParser
import Foundation

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Inspect recent AppleBooksCLI write and sync operation history.",
        subcommands: [
            HistoryListCommand.self,
            HistoryGetCommand.self,
        ]
    )
}

struct HistoryListCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List summaries for operation history retained during the last 24 hours."
    )

    @Option(name: .long, help: "Maximum history summaries to return (default 20, maximum 100).")
    var limit: Int?

    @Option(name: .long, help: "Opaque continuation cursor returned by a previous history list page.")
    var cursor: String?

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try run(output: output, store: OperationHistoryStore())
    }

    func run(output: CLIOutput, store: OperationHistoryStore) throws {
        let page = try CLIOperation.run {
            try store.listPage(limit: limit, cursor: cursor)
        }
        try output.writeJSON(HistoryListResult(page: page))
    }
}

struct HistoryGetCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get the complete record for one operation history ID."
    )

    @Argument(help: "Exact operation history ID from `history list`.")
    var id: String

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try run(output: output, store: OperationHistoryStore())
    }

    func run(output: CLIOutput, store: OperationHistoryStore) throws {
        let record = try CLIOperation.run {
            guard let value = try store.get(id: id) else {
                throw CLIError.notFound("Operation history entry not found.")
            }
            return value
        }

        let result = HistoryDetailResult(record: record)
        try output.writeJSON(result)
    }
}

struct HistoryListResult: Codable, Equatable, Sendable {
    let items: [HistorySummary]
    @ExplicitNullString var nextCursor: String?
    let hasMore: Bool

    init(page: CursorPage<OperationHistorySummaryRecord>) {
        items = page.items.map(HistorySummary.init)
        nextCursor = page.nextCursor
        hasMore = page.hasMore
    }

}

struct HistorySummary: Codable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let completedAt: Date?
    let operation: String
    let status: OperationHistoryStatus
    let exitCode: Int32?

    init(record: OperationHistorySummaryRecord) {
        id = record.id
        startedAt = record.startedAt
        completedAt = record.completedAt
        operation = record.operation
        status = record.status
        exitCode = record.exitCode
    }

}

struct HistoryDetailResult: Codable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let completedAt: Date?
    let operation: String
    let status: OperationHistoryStatus
    let exitCode: Int32?
    let arguments: [String]
    let stdout: String?
    let stderr: String?

    init(record: OperationHistoryRecord) {
        id = record.id
        startedAt = record.startedAt
        completedAt = record.completedAt
        operation = record.operation
        status = record.status
        exitCode = record.exitCode
        arguments = record.arguments
        stdout = record.stdout
        stderr = record.stderr
    }

}

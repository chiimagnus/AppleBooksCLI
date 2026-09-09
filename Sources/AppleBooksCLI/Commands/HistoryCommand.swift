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

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try run(output: output, store: OperationHistoryStore())
    }

    func run(output: CLIOutput, store: OperationHistoryStore) throws {
        let result = try HistoryListResult(records: historyRecords(from: store))
        try output.writeJSON(result)
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
        let record: OperationHistoryRecord
        do {
            guard let value = try store.get(id: id) else {
                throw CLIError.notFound("Operation history entry not found.")
            }
            record = value
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.unavailable("Operation history is unavailable.")
        }

        let result = HistoryDetailResult(record: record)
        try output.writeJSON(result)
    }
}

struct HistoryListResult: Codable, Equatable, Sendable {
    let items: [HistorySummary]

    init(records: [OperationHistoryRecord]) {
        items = records.map(HistorySummary.init)
    }

}

struct HistorySummary: Codable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let completedAt: Date?
    let operation: String
    let status: OperationHistoryStatus
    let exitCode: Int32?

    init(record: OperationHistoryRecord) {
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

private func historyRecords(from store: OperationHistoryStore) throws -> [OperationHistoryRecord] {
    do {
        return try store.list()
    } catch {
        throw CLIError.unavailable("Operation history is unavailable.")
    }
}

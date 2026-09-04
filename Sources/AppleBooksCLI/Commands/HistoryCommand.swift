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

struct HistoryListCommand: ParsableCommand, JSONOutputProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List summaries for operation history retained during the last 24 hours."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    var jsonRequested: Bool { json }

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try run(output: output, store: OperationHistoryStore())
    }

    func run(output: CLIOutput, store: OperationHistoryStore) throws {
        let result = try HistoryListResult(records: historyRecords(from: store))
        if json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct HistoryGetCommand: ParsableCommand, JSONOutputProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get the complete record for one operation history ID."
    )

    @Argument(help: "Exact operation history ID from `history list`.")
    var id: String

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    var jsonRequested: Bool { json }

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
        if json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct HistoryListResult: Codable, Equatable, Sendable {
    let items: [HistorySummary]

    init(records: [OperationHistoryRecord]) {
        items = records.map(HistorySummary.init)
    }

    var humanDescription: String {
        items.isEmpty ? "No history." : items.map(\.humanDescription).joined(separator: "\n")
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

    var humanDescription: String {
        let exit = exitCode.map(String.init) ?? "-"
        return "\(HistoryPresentation.timestamp(startedAt))  \(id)  \(operation)  \(status.rawValue)  exit=\(exit)"
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

    var humanDescription: String {
        [
            "id: \(id)",
            "started: \(HistoryPresentation.timestamp(startedAt))",
            "completed: \(completedAt.map(HistoryPresentation.timestamp) ?? "-")",
            "operation: \(operation)",
            "status: \(status.rawValue)",
            "exit: \(exitCode.map(String.init) ?? "-")",
            "arguments: \(HistoryPresentation.jsonLiteral(arguments))",
            "stdout: \(HistoryPresentation.optionalJSONLiteral(stdout))",
            "stderr: \(HistoryPresentation.optionalJSONLiteral(stderr))",
        ].joined(separator: "\n")
    }
}

private func historyRecords(from store: OperationHistoryStore) throws -> [OperationHistoryRecord] {
    do {
        return try store.list()
    } catch {
        throw CLIError.unavailable("Operation history is unavailable.")
    }
}

private enum HistoryPresentation {
    static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func jsonLiteral<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    static func optionalJSONLiteral(_ value: String?) -> String {
        value.map(jsonLiteral) ?? "null"
    }
}

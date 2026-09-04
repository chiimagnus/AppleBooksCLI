import AppleBooksCore
import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand, GlobalOptionsProviding, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Apple Books access and capability readiness without modifying data."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        let workerReady = (try? installedPDFWorkerURL()) != nil
        try execute(output: output, installedPDFWorkerReady: workerReady)
    }

    func execute(
        output: CLIOutput,
        databaseDiscovery: DatabaseDiscovery = DatabaseDiscovery(),
        backupRoot: URL = SQLiteBackup.defaultRoot(),
        installedPDFWorkerReady: Bool? = nil
    ) throws {
        let context = CLIContext(global: global, databaseDiscovery: databaseDiscovery)
        let result = DoctorResult(
            report: context.diagnostics(backupRoot: backupRoot),
            installedPDFWorkerReady: installedPDFWorkerReady
        )
        if global.json {
            try output.writeJSON(result)
        } else {
            output.stdout(result.humanDescription)
        }
    }
}

struct DoctorResult: Codable, Equatable, Sendable {
    let status: AppleBooksDiagnosticState
    let libraryDatabaseReady: Bool
    let annotationsDatabaseReady: Bool
    let readSchemaReady: Bool
    let optionalSchemaComplete: Bool
    let writeSchemaReady: Bool
    let configurationReady: Bool
    let supplementalRootConfigured: Bool
    let supplementalRootReady: Bool
    let backupLocationReady: Bool
    let booksAppRunning: Bool
    let installedPDFWorkerReady: Bool?
    let issues: [AppleBooksDiagnosticIssue]

    init(report: AppleBooksDiagnosticReport, installedPDFWorkerReady: Bool? = nil) {
        if report.state == .ready, installedPDFWorkerReady == false {
            status = .degraded
        } else {
            status = report.state
        }
        libraryDatabaseReady = report.libraryDatabaseReady
        annotationsDatabaseReady = report.annotationsDatabaseReady
        readSchemaReady = report.readSchemaReady
        optionalSchemaComplete = report.optionalSchemaComplete
        writeSchemaReady = report.writeSchemaReady
        configurationReady = report.configurationReady
        supplementalRootConfigured = report.supplementalRootConfigured
        supplementalRootReady = report.supplementalRootReady
        backupLocationReady = report.backupLocationReady
        booksAppRunning = report.booksAppRunning
        self.installedPDFWorkerReady = installedPDFWorkerReady
        if installedPDFWorkerReady == false {
            issues = report.issues + [.init(code: .pdfWorkerUnavailable, state: .degraded)]
        } else {
            issues = report.issues
        }
    }

    var humanDescription: String {
        var lines = [
            "AppleBooksCLI doctor: \(status.rawValue)",
            "library database: \(ready(libraryDatabaseReady))",
            "annotations database: \(ready(annotationsDatabaseReady))",
            "read schema: \(ready(readSchemaReady))",
            "optional schema: \(optionalSchemaComplete ? "complete" : "partial")",
            "write schema: \(ready(writeSchemaReady))",
            "configuration: \(ready(configurationReady))",
            "supplemental root: \(supplementalRootConfigured ? ready(supplementalRootReady) : "not configured")",
            "backup location: \(ready(backupLocationReady))",
            "Books.app: \(booksAppRunning ? "running" : "not running")",
        ]
        if let installedPDFWorkerReady {
            lines.append("PDF worker: \(ready(installedPDFWorkerReady))")
        }
        if issues.isEmpty == false {
            lines.append("issues:")
            lines.append(contentsOf: issues.map { "- \($0.code.rawValue)" })
        }
        return lines.joined(separator: "\n")
    }

    private func ready(_ value: Bool) -> String {
        value ? "ready" : "not ready"
    }
}

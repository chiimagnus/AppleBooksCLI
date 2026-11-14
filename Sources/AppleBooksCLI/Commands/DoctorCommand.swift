import AppleBooksCore
import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand, CLIOutputRunnable {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check Apple Books access and capability readiness without modifying data."
    )

    @OptionGroup var global: GlobalOptions

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try execute(output: output)
    }

    func execute(
        output: CLIOutput,
        databaseDiscovery: DatabaseDiscovery = DatabaseDiscovery(),
        backupRoot: URL = SQLiteBackup.defaultRoot()
    ) throws {
        let context = CLIContext(global: global, databaseDiscovery: databaseDiscovery)
        let result = DoctorResult(report: context.diagnostics(backupRoot: backupRoot))
        try output.writeJSON(result)
    }
}

enum DoctorOverallStatus: String, Codable, Equatable, Sendable {
    case ready
    case partial
    case unavailable
}

struct DoctorComponents: Codable, Equatable, Sendable {
    let libraryDatabaseReady: Bool
    let annotationsDatabaseReady: Bool
    let libraryReadReady: Bool
    let annotationsReadReady: Bool
    let collectionsReadReady: Bool
    let collectionWriteReady: Bool
    let annotationWriteReady: Bool
    let configurationReady: Bool
    let supplementalRootConfigured: Bool
    let supplementalRootReady: Bool
    let backupLocationReady: Bool
    let cloudSyncReady: Bool
    let libraryOptionalSchemaComplete: Bool
    let annotationsOptionalSchemaComplete: Bool
}

struct DoctorCapabilities: Codable, Equatable, Sendable {
    let booksRead: Bool
    let annotationsRead: Bool
    let collectionsRead: Bool
    let collectionsWrite: Bool
    let annotationWrite: Bool
    let contentReadPrerequisites: Bool
    let backups: Bool
    let syncPrerequisites: Bool

    var all: [Bool] {
        [
            booksRead,
            annotationsRead,
            collectionsRead,
            collectionsWrite,
            annotationWrite,
            contentReadPrerequisites,
            backups,
            syncPrerequisites,
        ]
    }
}

struct DoctorResult: Codable, Equatable, Sendable {
    let status: DoctorOverallStatus
    let components: DoctorComponents
    let capabilities: DoctorCapabilities
    let booksAppRunning: Bool
    let issues: [AppleBooksDiagnosticIssue]

    init(report: AppleBooksDiagnosticReport) {
        components = DoctorComponents(
            libraryDatabaseReady: report.libraryDatabaseReady,
            annotationsDatabaseReady: report.annotationsDatabaseReady,
            libraryReadReady: report.libraryReadReady,
            annotationsReadReady: report.annotationsReadReady,
            collectionsReadReady: report.collectionsReadReady,
            collectionWriteReady: report.collectionWriteReady,
            annotationWriteReady: report.annotationWriteReady,
            configurationReady: report.configurationReady,
            supplementalRootConfigured: report.supplementalRootConfigured,
            supplementalRootReady: report.supplementalRootReady,
            backupLocationReady: report.backupLocationReady,
            cloudSyncReady: report.cloudSyncReady,
            libraryOptionalSchemaComplete: report.libraryOptionalSchemaComplete,
            annotationsOptionalSchemaComplete: report.annotationsOptionalSchemaComplete
        )
        capabilities = DoctorCapabilities(
            booksRead: report.libraryReadReady,
            annotationsRead: report.libraryReadReady && report.annotationsReadReady && report.configurationReady,
            collectionsRead: report.collectionsReadReady,
            collectionsWrite: report.collectionWriteReady && report.backupLocationReady,
            annotationWrite: report.annotationWriteReady && report.backupLocationReady,
            contentReadPrerequisites: report.contentReadPrerequisitesReady && report.configurationReady,
            backups: report.libraryDatabaseReady && report.backupLocationReady,
            syncPrerequisites: report.cloudSyncReady
        )
        if capabilities.all.allSatisfy({ $0 }) {
            status = .ready
        } else if capabilities.all.contains(true) {
            status = .partial
        } else {
            status = .unavailable
        }
        booksAppRunning = report.booksAppRunning
        issues = report.issues
    }
}

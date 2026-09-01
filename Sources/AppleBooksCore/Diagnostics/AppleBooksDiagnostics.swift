import Darwin
import Foundation

public enum AppleBooksDiagnosticState: String, Codable, Equatable, Sendable {
    case ready
    case degraded
    case fatal
}

public enum AppleBooksDiagnosticIssueCode: String, Codable, Equatable, Sendable {
    case libraryDatabaseMissing = "library_database_missing"
    case libraryDatabaseAmbiguous = "library_database_ambiguous"
    case libraryDatabasePermission = "library_database_permission"
    case libraryDatabaseInvalidOverride = "library_database_invalid_override"
    case libraryDatabaseUnreadable = "library_database_unreadable"
    case annotationsDatabaseMissing = "annotations_database_missing"
    case annotationsDatabaseAmbiguous = "annotations_database_ambiguous"
    case annotationsDatabasePermission = "annotations_database_permission"
    case annotationsDatabaseInvalidOverride = "annotations_database_invalid_override"
    case annotationsDatabaseUnreadable = "annotations_database_unreadable"
    case libraryReadSchemaIncompatible = "library_read_schema_incompatible"
    case annotationsReadSchemaIncompatible = "annotations_read_schema_incompatible"
    case libraryWriteSchemaIncompatible = "library_write_schema_incompatible"
    case annotationsWriteSchemaIncompatible = "annotations_write_schema_incompatible"
    case configurationInvalid = "configuration_invalid"
    case supplementalRootUnavailable = "supplemental_root_unavailable"
    case backupLocationUnavailable = "backup_location_unavailable"
    case pdfWorkerUnavailable = "pdf_worker_unavailable"
}

public struct AppleBooksDiagnosticIssue: Codable, Equatable, Sendable {
    public let code: AppleBooksDiagnosticIssueCode
    public let state: AppleBooksDiagnosticState

    public init(code: AppleBooksDiagnosticIssueCode, state: AppleBooksDiagnosticState) {
        self.code = code
        self.state = state
    }
}

public struct AppleBooksDiagnosticReport: Codable, Equatable, Sendable {
    public let state: AppleBooksDiagnosticState
    public let libraryDatabaseReady: Bool
    public let annotationsDatabaseReady: Bool
    public let readSchemaReady: Bool
    public let optionalSchemaComplete: Bool
    public let writeSchemaReady: Bool
    public let configurationReady: Bool
    public let supplementalRootConfigured: Bool
    public let supplementalRootReady: Bool
    public let backupLocationReady: Bool
    public let booksAppRunning: Bool
    public let issues: [AppleBooksDiagnosticIssue]
}

public enum AppleBooksDiagnostics {
    public static func inspect(
        libraryOverride: URL? = nil,
        annotationsOverride: URL? = nil,
        configurationFile: URL? = nil,
        databaseDiscovery: DatabaseDiscovery = DatabaseDiscovery(),
        backupRoot: URL = SQLiteBackup.defaultRoot()
    ) -> AppleBooksDiagnosticReport {
        inspect(
            libraryOverride: libraryOverride,
            annotationsOverride: annotationsOverride,
            configurationFile: configurationFile,
            databaseDiscovery: databaseDiscovery,
            backupRoot: backupRoot,
            booksApp: .live
        )
    }

    static func inspect(
        libraryOverride: URL?,
        annotationsOverride: URL?,
        configurationFile: URL?,
        databaseDiscovery: DatabaseDiscovery,
        backupRoot: URL,
        booksApp: BooksAppController
    ) -> AppleBooksDiagnosticReport {
        var issues: [AppleBooksDiagnosticIssue] = []

        let library = inspectDatabase(
            store: .library,
            override: libraryOverride,
            discovery: databaseDiscovery,
            issues: &issues
        )
        let annotations = inspectDatabase(
            store: .annotations,
            override: annotationsOverride,
            discovery: databaseDiscovery,
            issues: &issues
        )

        var readSchemaReady = true
        var optionalSchemaComplete = true
        var writeSchemaReady = true

        if let libraryConnection = library.connection {
            let schema = inspectReadSchema(
                on: libraryConnection,
                capabilities: SchemaCapability.allCases.filter { $0.table != .annotations }
            )
            if schema.requiredReady == false {
                readSchemaReady = false
                issues.append(.init(code: .libraryReadSchemaIncompatible, state: .fatal))
            }
            optionalSchemaComplete = optionalSchemaComplete && schema.optionalComplete

            do {
                try CollectionWriter.validateWriteReadiness(on: libraryConnection)
            } catch {
                writeSchemaReady = false
                issues.append(.init(code: .libraryWriteSchemaIncompatible, state: .degraded))
            }
        } else {
            readSchemaReady = false
            optionalSchemaComplete = false
            writeSchemaReady = false
        }

        if let annotationConnection = annotations.connection {
            let schema = inspectReadSchema(
                on: annotationConnection,
                capabilities: SchemaCapability.allCases.filter { $0.table == .annotations }
            )
            if schema.requiredReady == false {
                readSchemaReady = false
                issues.append(.init(code: .annotationsReadSchemaIncompatible, state: .fatal))
            }
            optionalSchemaComplete = optionalSchemaComplete && schema.optionalComplete

            do {
                try AnnotationWriter.validateWriteReadiness(on: annotationConnection)
            } catch {
                writeSchemaReady = false
                issues.append(.init(code: .annotationsWriteSchemaIncompatible, state: .degraded))
            }
        } else {
            readSchemaReady = false
            optionalSchemaComplete = false
            writeSchemaReady = false
        }

        let configuration: AppleBooksConfiguration?
        do {
            configuration = try configurationFile.map(AppleBooksConfiguration.init(fileURL:))
                ?? AppleBooksConfiguration.loadDefault()
        } catch {
            configuration = nil
            issues.append(.init(code: .configurationInvalid, state: .fatal))
        }

        let supplementalRootConfigured = configuration?.epubRoot != nil
        let supplementalRootReady: Bool
        if let supplementalRoot = configuration?.epubRoot {
            supplementalRootReady = EPUBSourceResolver.supplementalRootIsReady(supplementalRoot)
            if supplementalRootReady == false {
                issues.append(.init(code: .supplementalRootUnavailable, state: .degraded))
            }
        } else {
            supplementalRootReady = true
        }

        let backupReady = backupLocationIsReady(backupRoot)
        if backupReady == false {
            issues.append(.init(code: .backupLocationUnavailable, state: .degraded))
        }

        let finalState: AppleBooksDiagnosticState
        if issues.contains(where: { $0.state == .fatal }) {
            finalState = .fatal
        } else if issues.isEmpty == false {
            finalState = .degraded
        } else {
            finalState = .ready
        }

        return AppleBooksDiagnosticReport(
            state: finalState,
            libraryDatabaseReady: library.connection != nil,
            annotationsDatabaseReady: annotations.connection != nil,
            readSchemaReady: readSchemaReady,
            optionalSchemaComplete: optionalSchemaComplete,
            writeSchemaReady: writeSchemaReady,
            configurationReady: configuration != nil,
            supplementalRootConfigured: supplementalRootConfigured,
            supplementalRootReady: supplementalRootReady,
            backupLocationReady: backupReady,
            booksAppRunning: booksApp.isRunning(),
            issues: issues
        )
    }

    private struct DatabaseInspection {
        let connection: SQLiteConnection?
    }

    private static func inspectDatabase(
        store: AppleBooksStore,
        override: URL?,
        discovery: DatabaseDiscovery,
        issues: inout [AppleBooksDiagnosticIssue]
    ) -> DatabaseInspection {
        let url: URL
        switch discovery.probe(store: store, override: override) {
        case let .success(found):
            url = found
        case let .failure(error):
            issues.append(.init(code: issueCode(store: store, error: error), state: .fatal))
            return DatabaseInspection(connection: nil)
        }

        do {
            return DatabaseInspection(connection: try SQLiteConnection.readOnly(path: url.path))
        } catch {
            let code: AppleBooksDiagnosticIssueCode = store == .library
                ? .libraryDatabaseUnreadable
                : .annotationsDatabaseUnreadable
            issues.append(.init(code: code, state: .fatal))
            return DatabaseInspection(connection: nil)
        }
    }

    private static func issueCode(
        store: AppleBooksStore,
        error: DatabaseStoreProbeError
    ) -> AppleBooksDiagnosticIssueCode {
        switch (store, error) {
        case (.library, .missing): .libraryDatabaseMissing
        case (.library, .permission): .libraryDatabasePermission
        case (.library, .ambiguous): .libraryDatabaseAmbiguous
        case (.library, .invalidOverride): .libraryDatabaseInvalidOverride
        case (.annotations, .missing): .annotationsDatabaseMissing
        case (.annotations, .permission): .annotationsDatabasePermission
        case (.annotations, .ambiguous): .annotationsDatabaseAmbiguous
        case (.annotations, .invalidOverride): .annotationsDatabaseInvalidOverride
        }
    }

    private static func inspectReadSchema(
        on connection: SQLiteConnection,
        capabilities: [SchemaCapability]
    ) -> (requiredReady: Bool, optionalComplete: Bool) {
        var optionalComplete = true
        for capability in capabilities {
            do {
                let availability = try AppleBooksSchema.inspect(capability, on: connection)
                if capability.optional.contains(where: { availability.contains($0) == false }) {
                    optionalComplete = false
                }
            } catch {
                return (false, false)
            }
        }
        return (true, optionalComplete)
    }

    private static func backupLocationIsReady(_ rawRoot: URL) -> Bool {
        var candidate = rawRoot.standardizedFileURL
        while true {
            var metadata = stat()
            if lstat(candidate.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT == S_IFDIR else { return false }
                return access(candidate.path, W_OK | X_OK) == 0
            }
            guard errno == ENOENT || errno == ENOTDIR else { return false }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            guard parent.path != candidate.path else { return false }
            candidate = parent
        }
    }
}

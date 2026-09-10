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
    case cloudSyncUnavailable = "cloud_sync_unavailable"
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
    public let libraryReadReady: Bool
    public let annotationsReadReady: Bool
    public let collectionsReadReady: Bool
    public let collectionWriteReady: Bool
    public let annotationWriteReady: Bool
    public let contentReadPrerequisitesReady: Bool
    public let pdfReadPrerequisitesReady: Bool
    public let libraryOptionalSchemaComplete: Bool
    public let annotationsOptionalSchemaComplete: Bool
    public let configurationReady: Bool
    public let supplementalRootConfigured: Bool
    public let supplementalRootReady: Bool
    public let backupLocationReady: Bool
    public let cloudSyncReady: Bool
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
            booksApp: .live,
            cloudSyncReadiness: Self.cloudSyncReadiness
        )
    }

    static func inspect(
        libraryOverride: URL?,
        annotationsOverride: URL?,
        configurationFile: URL?,
        databaseDiscovery: DatabaseDiscovery,
        backupRoot: URL,
        booksApp: BooksAppController,
        cloudSyncReadiness: (URL, URL) -> Bool
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

        var libraryReadReady = false
        var annotationsReadReady = false
        var collectionsReadReady = false
        var collectionWriteReady = false
        var annotationWriteReady = false
        var contentReadPrerequisitesReady = false
        var pdfReadPrerequisitesReady = false
        var libraryOptionalSchemaComplete = false
        var annotationsOptionalSchemaComplete = false

        if let libraryConnection = library.connection {
            let schema = inspectReadSchema(
                on: libraryConnection,
                capabilities: SchemaCapability.allCases.filter { $0.table != .annotations }
            )
            libraryOptionalSchemaComplete = schema.optionalComplete
            if schema.requiredReady == false {
                issues.append(.init(code: .libraryReadSchemaIncompatible, state: .fatal))
            }

            libraryReadReady = capabilitiesReady(
                [.bookBase, .bookAssetLookup],
                on: libraryConnection
            )
            collectionsReadReady = capabilitiesReady(
                [.collectionBase, .collectionTitleSearch, .collectionIDLookup, .collectionMembers, .collectionMemberBooks],
                on: libraryConnection
            )
            contentReadPrerequisitesReady = capabilitiesReady(
                [.bookAssetLookup, .bookContentPathLookup],
                on: libraryConnection
            )
            pdfReadPrerequisitesReady = capabilitiesReady(
                [.bookAssetLookup, .bookPDF],
                on: libraryConnection
            )

            do {
                try CollectionWriter.validateWriteReadiness(on: libraryConnection)
                collectionWriteReady = true
            } catch {
                issues.append(.init(code: .libraryWriteSchemaIncompatible, state: .degraded))
            }
        }

        if let annotationConnection = annotations.connection {
            let schema = inspectReadSchema(
                on: annotationConnection,
                capabilities: SchemaCapability.allCases.filter { $0.table == .annotations }
            )
            annotationsOptionalSchemaComplete = schema.optionalComplete
            if schema.requiredReady == false {
                issues.append(.init(code: .annotationsReadSchemaIncompatible, state: .fatal))
            }

            annotationsReadReady = capabilitiesReady(
                [.annotationUserBase, .annotationByUUID, .annotationByAssetID],
                on: annotationConnection
            )

            do {
                try AnnotationWriter.validateWriteReadiness(on: annotationConnection)
                annotationWriteReady = true
            } catch {
                issues.append(.init(code: .annotationsWriteSchemaIncompatible, state: .degraded))
            }
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

        let cloudSyncReady: Bool
        if let libraryURL = library.url, let annotationsURL = annotations.url {
            cloudSyncReady = cloudSyncReadiness(libraryURL, annotationsURL)
            if cloudSyncReady == false {
                issues.append(.init(code: .cloudSyncUnavailable, state: .degraded))
            }
        } else {
            cloudSyncReady = false
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
            libraryReadReady: libraryReadReady,
            annotationsReadReady: annotationsReadReady,
            collectionsReadReady: collectionsReadReady,
            collectionWriteReady: collectionWriteReady,
            annotationWriteReady: annotationWriteReady,
            contentReadPrerequisitesReady: contentReadPrerequisitesReady,
            pdfReadPrerequisitesReady: pdfReadPrerequisitesReady,
            libraryOptionalSchemaComplete: libraryOptionalSchemaComplete,
            annotationsOptionalSchemaComplete: annotationsOptionalSchemaComplete,
            configurationReady: configuration != nil,
            supplementalRootConfigured: supplementalRootConfigured,
            supplementalRootReady: supplementalRootReady,
            backupLocationReady: backupReady,
            cloudSyncReady: cloudSyncReady,
            booksAppRunning: booksApp.isRunning(),
            issues: issues
        )
    }

    private struct DatabaseInspection {
        let url: URL?
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
            return DatabaseInspection(url: nil, connection: nil)
        }

        do {
            return DatabaseInspection(url: url, connection: try SQLiteConnection.readOnly(path: url.path))
        } catch {
            let code: AppleBooksDiagnosticIssueCode = store == .library
                ? .libraryDatabaseUnreadable
                : .annotationsDatabaseUnreadable
            issues.append(.init(code: code, state: .fatal))
            return DatabaseInspection(url: nil, connection: nil)
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

    private static func capabilitiesReady(
        _ capabilities: [SchemaCapability],
        on connection: SQLiteConnection
    ) -> Bool {
        for capability in capabilities {
            do {
                _ = try AppleBooksSchema.inspect(capability, on: connection)
            } catch {
                return false
            }
        }
        return true
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

    private static func cloudSyncReadiness(_ libraryDatabase: URL, _ annotationsDatabase: URL) -> Bool {
        guard let collection = CollectionCloudSynchronizer.live(libraryDatabase: libraryDatabase),
              let annotation = AnnotationCloudSynchronizer.live(annotationsDatabase: annotationsDatabase) else {
            return false
        }
        do {
            _ = try collection.pendingCount()
            _ = try annotation.pendingCount()
            return true
        } catch {
            return false
        }
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

import AppleBooksCore

enum CLIProcessExit: Int32, Equatable, Sendable {
    case success = 0
    case usageInvalid = 64
    case notFound = 66
    case unavailable = 69
    case `internal` = 70
    case writeSafety = 74
    case permission = 77
}

enum CLIErrorCode: String, Codable, Equatable, Sendable {
    case usageInvalid = "usage_invalid"
    case notFound = "not_found"
    case unavailable
    case `internal`
    case writeSafety = "write_safety"
    case permission
}

enum CLIError: Error, Equatable, Sendable {
    case usageInvalid(String)
    case notFound(String)
    case unavailable(String)
    case unavailableWithReason(message: String, reason: String)
    case internalFailure
    case writeSafety(String)
    case writeSafetyWithReason(message: String, reason: String)
    case permission(String)

    var code: CLIErrorCode {
        switch self {
        case .usageInvalid: .usageInvalid
        case .notFound: .notFound
        case .unavailable, .unavailableWithReason: .unavailable
        case .internalFailure: .internal
        case .writeSafety, .writeSafetyWithReason: .writeSafety
        case .permission: .permission
        }
    }

    var message: String {
        switch self {
        case let .usageInvalid(message),
             let .notFound(message),
             let .unavailable(message),
             let .writeSafety(message),
             let .writeSafetyWithReason(message, _),
             let .permission(message):
            message
        case let .unavailableWithReason(message, _):
            message
        case .internalFailure:
            "Internal error."
        }
    }

    var reason: String? {
        switch self {
        case let .unavailableWithReason(_, reason), let .writeSafetyWithReason(_, reason): reason
        default: nil
        }
    }

    var exitCode: CLIProcessExit {
        switch self {
        case .usageInvalid: .usageInvalid
        case .notFound: .notFound
        case .unavailable, .unavailableWithReason: .unavailable
        case .internalFailure: .internal
        case .writeSafety, .writeSafetyWithReason: .writeSafety
        case .permission: .permission
        }
    }
}

enum CLIOperation {
    static func run<Value>(_ operation: () throws -> Value) throws -> Value {
        do {
            return try operation()
        } catch let error as CLIError {
            throw error
        } catch {
            throw translate(error)
        }
    }

    private static func translate(_ error: Error) -> CLIError {
        if error is QueryPaginationError || error is PageInputError {
            return .usageInvalid("Invalid pagination parameters.")
        }
        if let cursorError = error as? CursorPaginationError {
            switch cursorError {
            case .limitOutOfRange, .invalidCursor, .filterMismatch:
                return .usageInvalid("Invalid pagination cursor or limit.")
            case .staleCursor, .generationUnavailable:
                return .unavailable("Pagination cursor is stale. Restart from the first page.")
            case .internalContractFailure:
                return .internalFailure
            }
        }
        if let pdfInventoryError = error as? PDFInventoryError {
            switch pdfInventoryError {
            case .invalidSourceID:
                return .usageInvalid("Invalid PDF source identity.")
            case .ambiguousSourceID:
                return .unavailable("PDF source identity is ambiguous. Run `applebookscli pdf list` again.")
            }
        }
        if let historyError = error as? OperationHistoryStoreError {
            switch historyError {
            case .invalidID:
                return .usageInvalid("Operation history ID must be a canonical lowercase UUID.")
            case .unavailable:
                return .unavailable("Operation history is unavailable.")
            }
        }
        if let searchError = error as? BookSearchError {
            switch searchError {
            case .emptyQuery:
                return .usageInvalid("Search query must not be empty.")
            case .noSearchableColumns:
                return .unavailable("Apple Books search schema is unavailable.")
            case .fieldUnavailable:
                return .unavailable("Requested Apple Books search field is unavailable.")
            }
        }
        if let annotationInputError = error as? AnnotationQueryInputError {
            switch annotationInputError {
            case .unknownColor:
                return .usageInvalid("Invalid annotation color.")
            case .invalidDateRange:
                return .usageInvalid("Invalid annotation date range.")
            }
        }
        if let collectionWriteError = error as? CollectionWriteError {
            switch collectionWriteError {
            case .invalidTitle:
                return .usageInvalid("Collection title is invalid.")
            case .collectionMissing:
                return .notFound("Collection not found.")
            case .bookMissing:
                return .notFound("Book not found.")
            case .collectionDeletedOrUnknown,
                 .collectionIdentityUnavailable,
                 .collectionNotEditable,
                 .bookAssetIDUnavailable,
                 .writeFailed:
                return .writeSafety("Collection mutation failed safely.")
            }
        }
        if let annotationWriteError = error as? AnnotationWriteError {
            switch annotationWriteError {
            case .invalidNoteLength:
                return .usageInvalid("Annotation note length is invalid.")
            case .annotationMissing:
                return .notFound("Annotation not found.")
            case .annotationDeletedOrUnknown, .annotationNotWritable:
                return .writeSafety("Annotation is not writable.")
            case .writeFailed:
                return .writeSafety("Annotation mutation failed safely.")
            }
        }
        if let mutationFailure = error as? MutationFailure {
            return .writeSafety("Apple Books mutation failed safely (\(mutationFailure.code.rawValue)).")
        }
        if let restoreFailure = error as? RestoreFailure {
            switch restoreFailure.code {
            case .sourceRejected:
                return .notFound("backupID is unavailable or invalid.")
            case .quitFailed, .safetyBackupFailed, .restoreFailed:
                return .writeSafety("Library restore failed safely (\(restoreFailure.code.rawValue)).")
            }
        }
        if error is LibraryBackupIdentityError {
            return .usageInvalid("Invalid backupID.")
        }
        if error is SQLiteBackupError {
            return .unavailable("Apple Books backup store is unavailable.")
        }
        if let discoveryError = error as? DatabaseDiscoveryError {
            switch discoveryError {
            case .invalidOverride:
                return .permission("Database override is not a readable regular file.")
            case .missing, .ambiguous:
                return .unavailable("Apple Books database is unavailable. Run `applebookscli doctor` for diagnostics.")
            }
        }
        if error is AppleBooksConfigurationError {
            return .unavailable("AppleBooksCLI configuration is invalid.")
        }
        if error is SchemaCompatibilityError || error is QueryDecodingError || error is SQLiteRowError || error is SQLiteError {
            return .unavailable("Apple Books database schema or data is unavailable.")
        }
        if error is StableIdentityError {
            return .unavailable("Requested stable identity is ambiguous.")
        }
        if error is AnnotationSourceClassificationError {
            return .unavailable("Annotation source classification is unavailable.")
        }
        if let cloudSyncError = error as? AppleBooksCloudSyncError {
            switch cloudSyncError {
            case .unavailable:
                return .unavailable("Apple Books cloud sync is unavailable for the selected databases.")
            case .acknowledgementFailed:
                return .unavailable("Apple Books cloud sync did not reach acknowledgement.")
            }
        }
        if error as? AppleBooksDependencyError == .unavailable(.pdfWorker) {
            return .unavailable("PDF worker is unavailable.")
        }
        if error is PDFWorkerClientError {
            return .unavailable("PDF highlight extraction is unavailable.")
        }
        if let contextError = error as? AnnotationContextError {
            switch contextError {
            case .invalidWindow:
                return .usageInvalid("Invalid annotation context window.")
            case .annotationUnavailable:
                return .notFound("Annotation not found.")
            case .assetIdentityUnavailable,
                 .currentBookUnavailable,
                 .currentBookAmbiguous,
                 .contentPathUnavailable,
                 .chapterUnavailable,
                 .anchorUnavailable,
                 .anchorTooLarge,
                 .anchorNotFound:
                return .unavailable("Annotation context is unavailable.")
            }
        }
        if let contentError = error as? BookContentError {
            switch contentError {
            case .chapterNotFound:
                return .notFound("Chapter not found.")
            case .invalidMaximumCharacters:
                return .usageInvalid("Invalid chapter pagination parameters.")
            case .chapterOffsetOutOfRange:
                return .usageInvalid("Chapter offset is out of range.")
            }
        }
        if error is XHTMLTextError {
            return .unavailable("Book content is unavailable.")
        }
        if error is ContentError ||
            error is EPUBResourceError ||
            error is DirectoryEPUBPackageError ||
            error is EPUBNavigationError ||
            error is EPUBPathError ||
            error is EPUBMetadataError {
            return .unavailable("Book content is unavailable.")
        }
        if let optionsError = error as? ExportOptionsError {
            switch optionsError {
            case .emptyColors:
                return .usageInvalid("At least one export color is required when filtering by color.")
            case .invalidBookSelector:
                return .usageInvalid("Export book selector is invalid.")
            case .conflictingOptions:
                return .usageInvalid("Export options conflict.")
            }
        }
        if let exportError = error as? ExportServiceError {
            switch exportError {
            case .selectorNotFound:
                return .notFound("Export selector was not found. Refresh books or pdf list.")
            case .pdfWorkerUnavailable:
                return .unavailable("PDF worker is unavailable for the requested export source.")
            case .pdfSourceUnavailable:
                return .unavailable("Selected PDF is not locally readable. Refresh pdf list.")
            case .pdfReadFailed:
                return .unavailable("Selected PDF could not be read. Check its local availability.")
            case .documentIdentityCollision:
                return .unavailable("Export document identity is ambiguous.")
            }
        }
        if let writerError = error as? ExportFileWriterError {
            switch writerError {
            case .destinationExists:
                return .writeSafetyWithReason(message: "Output already exists. Choose another destination or explicitly allow overwrite.", reason: "output_exists")
            case .invalidOutputRoot, .unsafeOutputRoot, .invalidFileName, .unsafeParent, .unsafeDestination:
                return .writeSafetyWithReason(message: "Output path is unsafe or has the wrong node type.", reason: "unsafe_output")
            case .writeFailed:
                return .writeSafety("Output could not be written.")
            }
        }
        return .internalFailure
    }
}

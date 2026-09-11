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

enum CLIErrorReason: String, Codable, Equatable, Sendable, CaseIterable {
    case ambiguousIdentity = "ambiguous_identity"
    case annotationNotFound = "annotation_not_found"
    case annotationRestoreUnavailable = "annotation_restore_unavailable"
    case backupNotFound = "backup_not_found"
    case bookNotFound = "book_not_found"
    case chapterNotFound = "chapter_not_found"
    case collectionNotFound = "collection_not_found"
    case configurationInvalid = "configuration_invalid"
    case contentUnavailable = "content_unavailable"
    case contextUnavailable = "context_unavailable"
    case cursorStale = "cursor_stale"
    case databaseUnavailable = "database_unavailable"
    case historyEntryNotFound = "history_entry_not_found"
    case historyUnavailable = "history_unavailable"
    case outputExists = "output_exists"
    case pdfSourceNotFound = "pdf_source_not_found"
    case pdfWorkerUnavailable = "pdf_worker_unavailable"
    case readingOrderRequiresBook = "reading_order_requires_book"
    case readingPositionUnavailable = "reading_position_unavailable"
    case schemaUnavailable = "schema_unavailable"
    case selectorNotFound = "selector_not_found"
    case syncAckFailed = "sync_ack_failed"
    case syncUnavailable = "sync_unavailable"
    case unsafeOutput = "unsafe_output"
}

enum CLIError: Error, Equatable, Sendable {
    case usageInvalid(String)
    case usageInvalidWithReason(message: String, reason: CLIErrorReason)
    case notFound(String)
    case notFoundWithReason(message: String, reason: CLIErrorReason)
    case unavailable(String)
    case unavailableWithReason(message: String, reason: CLIErrorReason)
    case internalFailure
    case writeSafety(String)
    case writeSafetyWithReason(message: String, reason: CLIErrorReason)
    case permission(String)

    var code: CLIErrorCode {
        switch self {
        case .usageInvalid, .usageInvalidWithReason: .usageInvalid
        case .notFound, .notFoundWithReason: .notFound
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
             let .permission(message):
            message
        case let .usageInvalidWithReason(message, _),
             let .notFoundWithReason(message, _),
             let .unavailableWithReason(message, _),
             let .writeSafetyWithReason(message, _):
            message
        case .internalFailure:
            "Internal error."
        }
    }

    private var typedReason: CLIErrorReason? {
        switch self {
        case let .usageInvalidWithReason(_, reason),
             let .notFoundWithReason(_, reason),
             let .unavailableWithReason(_, reason),
             let .writeSafetyWithReason(_, reason):
            reason
        default:
            nil
        }
    }

    var reason: String? { typedReason?.rawValue }

    var recoveryHint: String? {
        switch typedReason {
        case .ambiguousIdentity:
            "Refresh the selector from the corresponding list or search command and retry with a unique returned identity."
        case .annotationNotFound:
            "Run `applebookscli annotations list` and retry with a returned selector."
        case .annotationRestoreUnavailable, .readingPositionUnavailable, nil:
            nil
        case .backupNotFound:
            "Run `applebookscli backups list` and retry with a returned backupID."
        case .bookNotFound:
            "Run `applebookscli books list` or `applebookscli books search` and retry with a returned selector."
        case .chapterNotFound:
            "Run `applebookscli content chapters` for the same book and retry with a returned chapter order."
        case .collectionNotFound:
            "Run `applebookscli collections list` or `applebookscli collections search` and retry with a returned selector."
        case .configurationInvalid:
            "Fix or remove the AppleBooksCLI configuration, then retry."
        case .contentUnavailable:
            "Check that the content is locally available and readable in Apple Books, then retry."
        case .contextUnavailable:
            "Refresh the annotation selector and make sure its book content is locally available before retrying."
        case .cursorStale:
            "Restart from the first page and continue with the new nextCursor."
        case .databaseUnavailable, .schemaUnavailable:
            "Run `applebookscli doctor` and resolve the reported Apple Books data access issue."
        case .historyEntryNotFound:
            "Run `applebookscli history list` and retry with a returned history ID."
        case .historyUnavailable:
            "Retry after local operation history storage is accessible."
        case .outputExists:
            "Choose a different --output; for export, use --overwrite always only when replacement is intended."
        case .pdfSourceNotFound:
            "Run `applebookscli pdf list` and retry with a returned selector."
        case .pdfWorkerUnavailable:
            "Run `applebookscli doctor`; reinstall AppleBooksCLI if the PDF worker is unavailable."
        case .readingOrderRequiresBook:
            "Provide exactly one of --book or --book-pk with --order reading."
        case .selectorNotFound:
            "Refresh the selector with `applebookscli books list` or `applebookscli pdf list`, then retry."
        case .syncAckFailed:
            "It is safe to rerun `applebookscli sync`."
        case .syncUnavailable:
            "Run `applebookscli doctor` and resolve sync prerequisites before retrying."
        case .unsafeOutput:
            "Choose a different --output destination."
        }
    }

    var exitCode: CLIProcessExit {
        switch self {
        case .usageInvalid, .usageInvalidWithReason: .usageInvalid
        case .notFound, .notFoundWithReason: .notFound
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
        if let cursorError = error as? CursorPaginationError {
            switch cursorError {
            case .limitOutOfRange, .invalidCursor, .filterMismatch:
                return .usageInvalid("Invalid pagination cursor or limit.")
            case .staleCursor, .generationUnavailable:
                return .unavailableWithReason(
                    message: "Pagination cursor is stale.",
                    reason: .cursorStale
                )
            case .internalContractFailure:
                return .internalFailure
            }
        }
        if let pdfInventoryError = error as? PDFInventoryError {
            switch pdfInventoryError {
            case .invalidSourceID:
                return .usageInvalid("Invalid PDF source identity.")
            case .ambiguousSourceID:
                return .unavailableWithReason(
                    message: "PDF source selector is ambiguous.",
                    reason: .ambiguousIdentity
                )
            }
        }
        if let historyError = error as? OperationHistoryStoreError {
            switch historyError {
            case .invalidID:
                return .usageInvalid("Operation history ID must be a lowercase UUID returned by `history list`.")
            case .unavailable:
                return .unavailableWithReason(
                    message: "Operation history is unavailable.",
                    reason: .historyUnavailable
                )
            }
        }
        if let searchError = error as? BookSearchError {
            switch searchError {
            case .emptyQuery:
                return .usageInvalid("Search query must not be empty.")
            case .noSearchableColumns:
                return .unavailableWithReason(
                    message: "Apple Books search is unavailable.",
                    reason: .schemaUnavailable
                )
            case .fieldUnavailable:
                return .unavailableWithReason(
                    message: "Requested Apple Books search field is unavailable.",
                    reason: .schemaUnavailable
                )
            }
        }
        if error is AnnotationQueryInputError {
            return .usageInvalid("Invalid annotation color.")
        }
        if let collectionWriteError = error as? CollectionWriteError {
            switch collectionWriteError {
            case .invalidTitle:
                return .usageInvalid("Collection title is invalid.")
            case .collectionMissing:
                return .notFoundWithReason(message: "Collection not found.", reason: .collectionNotFound)
            case .bookMissing:
                return .notFoundWithReason(message: "Book not found.", reason: .bookNotFound)
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
                return .notFoundWithReason(message: "Annotation not found.", reason: .annotationNotFound)
            case .annotationRestoreUnavailable:
                return .notFoundWithReason(
                    message: "Annotation tombstone is unavailable.",
                    reason: .annotationRestoreUnavailable
                )
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
                return .notFoundWithReason(
                    message: "backupID is unavailable or invalid.",
                    reason: .backupNotFound
                )
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
                return .unavailableWithReason(
                    message: "Apple Books database is unavailable.",
                    reason: .databaseUnavailable
                )
            }
        }
        if error is AppleBooksConfigurationError {
            return .unavailableWithReason(
                message: "AppleBooksCLI configuration is invalid.",
                reason: .configurationInvalid
            )
        }
        if error is SchemaCompatibilityError || error is QueryDecodingError || error is SQLiteRowError || error is SQLiteError {
            return .unavailableWithReason(
                message: "Apple Books data is unavailable.",
                reason: .schemaUnavailable
            )
        }
        if error is StableIdentityError {
            return .unavailableWithReason(
                message: "Requested selector is ambiguous.",
                reason: .ambiguousIdentity
            )
        }
        if error is AnnotationSourceClassificationError {
            return .unavailable("Annotation source classification is unavailable.")
        }
        if let cloudSyncError = error as? AppleBooksCloudSyncError {
            switch cloudSyncError {
            case .unavailable:
                return .unavailableWithReason(
                    message: "Apple Books sync is unavailable.",
                    reason: .syncUnavailable
                )
            case let .acknowledgementFailed(stateRestoreFailed):
                return .unavailableWithReason(
                    message: stateRestoreFailed
                        ? "Apple Books cloud sync did not reach acknowledgement, and the original Books app state could not be restored."
                        : "Apple Books cloud sync did not reach acknowledgement.",
                    reason: .syncAckFailed
                )
            }
        }
        if error as? AppleBooksDependencyError == .unavailable(.pdfWorker) {
            return .unavailableWithReason(message: "PDF worker is unavailable.", reason: .pdfWorkerUnavailable)
        }
        if error is PDFWorkerClientError {
            return .unavailableWithReason(
                message: "PDF highlight extraction is unavailable.",
                reason: .pdfWorkerUnavailable
            )
        }
        if let contextError = error as? AnnotationContextError {
            switch contextError {
            case .invalidWindow:
                return .usageInvalid("Invalid annotation context window.")
            case .assetIdentityUnavailable,
                 .currentBookUnavailable,
                 .currentBookAmbiguous,
                 .contentPathUnavailable,
                 .chapterUnavailable,
                 .anchorUnavailable,
                 .anchorTooLarge,
                 .anchorNotFound:
                return .unavailableWithReason(
                    message: "Annotation context is unavailable.",
                    reason: .contextUnavailable
                )
            }
        }
        if let contentError = error as? BookContentError {
            switch contentError {
            case .chapterNotFound:
                return .notFoundWithReason(message: "Chapter not found.", reason: .chapterNotFound)
            case .invalidMaximumCharacters:
                return .usageInvalid("Invalid chapter pagination parameters.")
            }
        }
        if error is XHTMLTextError {
            return .unavailableWithReason(
                message: "Book content is unavailable.",
                reason: .contentUnavailable
            )
        }
        if error is ContentError ||
            error is EPUBResourceError ||
            error is DirectoryEPUBPackageError ||
            error is EPUBNavigationError ||
            error is EPUBPathError ||
            error is EPUBMetadataError {
            return .unavailableWithReason(
                message: "Book content is unavailable.",
                reason: .contentUnavailable
            )
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
                return .notFoundWithReason(
                    message: "Export selector was not found.",
                    reason: .selectorNotFound
                )
            case .pdfWorkerUnavailable:
                return .unavailableWithReason(
                    message: "PDF worker is unavailable for the requested export source.",
                    reason: .pdfWorkerUnavailable
                )
            case .pdfSourceUnavailable:
                return .unavailableWithReason(
                    message: "Selected PDF is not locally readable.",
                    reason: .contentUnavailable
                )
            case .pdfReadFailed:
                return .unavailableWithReason(
                    message: "Selected PDF could not be read.",
                    reason: .contentUnavailable
                )
            case .documentIdentityCollision:
                return .unavailableWithReason(
                    message: "Export document identity is ambiguous.",
                    reason: .ambiguousIdentity
                )
            }
        }
        if let writerError = error as? ExportFileWriterError {
            switch writerError {
            case .destinationExists:
                return .writeSafetyWithReason(message: "Output already exists.", reason: .outputExists)
            case .invalidOutputRoot, .unsafeOutputRoot, .invalidFileName, .unsafeParent, .unsafeDestination:
                return .writeSafetyWithReason(message: "Output path is unsafe or has the wrong node type.", reason: .unsafeOutput)
            case .writeFailed:
                return .writeSafety("Output could not be written.")
            }
        }
        return .internalFailure
    }
}

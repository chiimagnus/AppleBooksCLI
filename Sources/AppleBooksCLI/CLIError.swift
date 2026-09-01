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
    case internalFailure
    case writeSafety(String)
    case permission(String)

    var code: CLIErrorCode {
        switch self {
        case .usageInvalid: .usageInvalid
        case .notFound: .notFound
        case .unavailable: .unavailable
        case .internalFailure: .internal
        case .writeSafety: .writeSafety
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
        case .internalFailure:
            "Internal error."
        }
    }

    var exitCode: CLIProcessExit {
        switch self {
        case .usageInvalid: .usageInvalid
        case .notFound: .notFound
        case .unavailable: .unavailable
        case .internalFailure: .internal
        case .writeSafety: .writeSafety
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
        if let searchError = error as? BookSearchError {
            switch searchError {
            case .emptyQuery:
                return .usageInvalid("Search query must not be empty.")
            case .noSearchableColumns:
                return .unavailable("Apple Books search schema is unavailable.")
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
            case .annotationDeletedOrUnknown:
                return .writeSafety("Annotation is not writable.")
            case .writeFailed:
                return .writeSafety("Annotation mutation failed safely.")
            }
        }
        if let mutationFailure = error as? MutationFailure {
            return .writeSafety("Apple Books mutation failed safely (\(mutationFailure.code.rawValue)).")
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
        if error is SchemaCompatibilityError || error is QueryDecodingError || error is SQLiteError {
            return .unavailable("Apple Books database schema or data is unavailable.")
        }
        if error is StableIdentityError {
            return .unavailable("Requested stable identity is ambiguous.")
        }
        if error is PDFHighlightFacadeError {
            return .unavailable("PDF worker is unavailable.")
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
        if error is ExportFileWriterError {
            return .writeSafety("Output path is unsafe or already exists.")
        }
        return .internalFailure
    }
}

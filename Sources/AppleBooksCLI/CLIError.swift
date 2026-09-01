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

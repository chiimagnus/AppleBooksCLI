import Foundation

struct CLIOutput {
    let stdout: (String) -> Void
    let stderr: (String) -> Void

    static var standard: CLIOutput {
        CLIOutput(
            stdout: { write($0, to: .standardOutput) },
            stderr: { write($0, to: .standardError) }
        )
    }

    func writeJSON<Value: Encodable>(_ value: Value) throws {
        stdout(String(decoding: try Self.encode(value), as: UTF8.self))
    }

    func writeErrorJSON<Value: Encodable>(_ value: Value) throws {
        stderr(String(decoding: try Self.encode(value), as: UTF8.self))
    }

    func writeDiagnostic(_ diagnostic: CLIDiagnosticEnvelope) throws {
        stderr(String(decoding: try Self.encode(diagnostic), as: UTF8.self) + "\n")
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func write(_ text: String, to handle: FileHandle) {
        let suffix = text.hasSuffix("\n") ? "" : "\n"
        handle.write(Data((text + suffix).utf8))
    }
}

@propertyWrapper
struct ExplicitNullString: Codable, Equatable, Sendable {
    var wrappedValue: String?

    init(wrappedValue: String?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: ExplicitNullString.Type, forKey key: Key) throws -> ExplicitNullString {
        try decodeIfPresent(type, forKey: key) ?? ExplicitNullString(wrappedValue: nil)
    }
}

@propertyWrapper
struct ExplicitNullBool: Codable, Equatable, Sendable {
    var wrappedValue: Bool?

    init(wrappedValue: Bool?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Bool.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: ExplicitNullBool.Type, forKey key: Key) throws -> ExplicitNullBool {
        try decodeIfPresent(type, forKey: key) ?? ExplicitNullBool(wrappedValue: nil)
    }
}

struct CLIErrorEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let code: CLIErrorCode
        let reason: String?
        let message: String
        let recoveryHint: String?

        private enum CodingKeys: String, CodingKey {
            case code
            case reason
            case message
            case recoveryHint
        }

        init(code: CLIErrorCode, reason: String?, message: String, recoveryHint: String?) {
            self.code = code
            self.reason = reason
            self.message = message
            self.recoveryHint = recoveryHint
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try container.decode(CLIErrorCode.self, forKey: .code)
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
            message = try container.decode(String.self, forKey: .message)
            recoveryHint = try container.decodeIfPresent(String.self, forKey: .recoveryHint)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(code, forKey: .code)
            if let reason {
                try container.encode(reason, forKey: .reason)
            } else {
                try container.encodeNil(forKey: .reason)
            }
            try container.encode(message, forKey: .message)
            if let recoveryHint {
                try container.encode(recoveryHint, forKey: .recoveryHint)
            } else {
                try container.encodeNil(forKey: .recoveryHint)
            }
        }
    }

    let ok: Bool
    let error: Payload

    init(_ error: CLIError) {
        ok = false
        self.error = Payload(
            code: error.code,
            reason: error.reason,
            message: error.message,
            recoveryHint: error.recoveryHint
        )
    }
}

enum CLIDiagnosticSeverity: String, Codable, Equatable, Sendable {
    case warning
}

struct CLIDiagnosticEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let severity: CLIDiagnosticSeverity
        let code: String
        let message: String
    }

    let diagnostic: Payload

    static let historyCompletionFailed = CLIDiagnosticEnvelope(
        diagnostic: Payload(
            severity: .warning,
            code: "history_completion_failed",
            message: "Operation history completion was not recorded."
        )
    )
}

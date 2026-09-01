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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        stdout(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    private static func write(_ text: String, to handle: FileHandle) {
        let suffix = text.hasSuffix("\n") ? "" : "\n"
        handle.write(Data((text + suffix).utf8))
    }
}

struct CLIErrorEnvelope: Codable, Equatable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let code: CLIErrorCode
        let message: String
    }

    let ok: Bool
    let error: Payload

    init(_ error: CLIError) {
        ok = false
        self.error = Payload(code: error.code, message: error.message)
    }
}

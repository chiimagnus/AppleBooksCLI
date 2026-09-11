import ArgumentParser
import Foundation
import Testing
@testable import AppleBooksCLI
@testable import AppleBooksCore

@Suite("OutputContractTests")
struct OutputContractTests {
    @Test
    func parseFailureIsSanitizedJsonOnStderrOnly() throws {
        let sentinel = "secret-value-DO-NOT-ECHO"
        let capture = Capture()

        let code = CLIEntrypoint.run(
            arguments: ["books", "list", "--definitely-unknown", sentinel],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains(sentinel) == false)
        #expect(capture.stderr.contains("definitely-unknown") == false)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope == CLIErrorEnvelope(.usageInvalid("Invalid command-line arguments.")))
        #expect(envelope.error.reason == nil)
        #expect(envelope.error.recoveryHint == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(capture.stderr.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(error["reason"] is NSNull)
        #expect(error["recoveryHint"] is NSNull)
    }

    @Test
    func removedJsonAndVerboseFlagsAreNotCompatibilityAliases() throws {
        for removedFlag in ["--json", "--verbose"] {
            let capture = Capture()
            let code = CLIEntrypoint.run(
                arguments: ["books", "list", removedFlag],
                output: capture.output
            )

            #expect(code == CLIProcessExit.usageInvalid.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try decodeError(capture.stderr)
            #expect(envelope.error.code == .usageInvalid)
            #expect(envelope.error.message == "Invalid command-line arguments.")
            #expect(capture.stderr.contains(removedFlag) == false)
        }
    }

    @Test
    func helpAndVersionRemainPlainTextCleanExits() {
        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["--help"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stderr.isEmpty)
        #expect(help.stdout.contains("USAGE:"))
        #expect((try? JSONSerialization.jsonObject(with: Data(help.stdout.utf8))) == nil)

        let version = Capture()
        let versionCode = CLIEntrypoint.run(arguments: ["--version"], output: version.output)
        #expect(versionCode == CLIProcessExit.success.rawValue)
        #expect(version.stderr.isEmpty)
        #expect(version.stdout == "dev")
    }

    @Test
    func typedErrorsHaveStableCodesMessagesAndExitNumbersOnStderr() throws {
        let cases: [(CLIError, CLIErrorCode, CLIProcessExit)] = [
            (.usageInvalid("bad usage"), .usageInvalid, .usageInvalid),
            (.notFound("missing"), .notFound, .notFound),
            (.unavailable("unavailable"), .unavailable, .unavailable),
            (.internalFailure, .internal, .internal),
            (.writeSafety("unsafe write"), .writeSafety, .writeSafety),
            (.permission("denied"), .permission, .permission),
        ]

        for (error, expectedCode, expectedExit) in cases {
            let capture = Capture()
            let code = CLIEntrypoint.presentRunError(error, output: capture.output)
            #expect(code == expectedExit.rawValue)
            #expect(capture.stdout.isEmpty)
            let envelope = try decodeError(capture.stderr)
            #expect(envelope.error.code == expectedCode)
            #expect(envelope.error.message == error.message)
            #expect(envelope.error.reason == nil)
            #expect(envelope.error.recoveryHint == nil)
        }
    }

    @Test
    func validationErrorMapsToUsageInvalidJsonOnStderr() throws {
        let capture = Capture()
        let code = CLIEntrypoint.presentRunError(
            ValidationError("invalid selection"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "invalid selection")
    }

    @Test
    func cleanRunExitUsesOfficialArgumentParserTextOnStdout() {
        let capture = Capture()
        let code = CLIEntrypoint.presentRunError(
            CleanExit.message("clean message"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.success.rawValue)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout == "clean message")
    }

    @Test
    func unexpectedRunErrorIsSanitizedAndNeverReflectsPayload() throws {
        struct PrivateFailure: Error {
            let secret: String
        }
        let capture = Capture()

        let code = CLIEntrypoint.presentRunError(
            PrivateFailure(secret: "private-payload"),
            output: capture.output
        )

        #expect(code == CLIProcessExit.internal.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains("private-payload") == false)
        let envelope = try decodeError(capture.stderr)
        #expect(envelope.error.code == .internal)
        #expect(envelope.error.message == "Internal error.")
    }

    @Test
    func mutationOutcomeAlwaysEncodesAcknowledgementStateExplicitly() throws {
        let noSync = MutationCommandResult(MutationResult(
            committed: false,
            backupHandle: nil,
            localPK: 1,
            stableID: "stable",
            changed: false,
            acknowledgementRequested: false,
            acknowledged: nil,
            warnings: []
        ))
        let requestedNoOp = MutationCommandResult(MutationResult(
            committed: false,
            backupHandle: nil,
            localPK: 1,
            stableID: "stable",
            changed: false,
            acknowledgementRequested: true,
            acknowledged: nil,
            warnings: []
        ))

        for (result, requested) in [(noSync, false), (requestedNoOp, true)] {
            let data = try JSONEncoder().encode(result)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["acknowledgementRequested"] as? Bool == requested)
            #expect(object["acknowledged"] is NSNull)
            #expect(try JSONDecoder().decode(MutationCommandResult.self, from: data) == result)
        }
    }

    @Test
    func genericJsonWriterEmitsOneCompactValueWithoutDiagnostics() throws {
        struct Result: Codable, Equatable {
            let value: String
        }

        let capture = Capture()
        try capture.output.writeJSON(Result(value: "ok"))
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout == #"{"value":"ok"}"#)
        #expect(try JSONDecoder().decode(Result.self, from: Data(capture.stdout.utf8)) == Result(value: "ok"))
    }

    @Test
    func diagnosticWriterUsesOneSanitizedJsonLineOnStderr() throws {
        let capture = Capture()
        try capture.output.writeDiagnostic(.historyCompletionFailed)

        #expect(capture.stdout.isEmpty)
        let decoded = try JSONDecoder().decode(
            CLIDiagnosticEnvelope.self,
            from: Data(capture.stderr.utf8)
        )
        #expect(decoded == .historyCompletionFailed)
        #expect(decoded.diagnostic.severity == .warning)
    }

    private func decodeError(_ value: String) throws -> CLIErrorEnvelope {
        try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(value.utf8))
    }

    private final class Capture {
        var stdout = ""
        var stderr = ""

        var output: CLIOutput {
            CLIOutput(
                stdout: { [self] text in stdout += text },
                stderr: { [self] text in stderr += text }
            )
        }
    }
}

import ArgumentParser
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("OutputContractTests")
struct OutputContractTests {
    @Test
    func humanParseFailureUsesUsageExitAndStderrOnly() {
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["--unknown-option"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stdout.isEmpty)
        #expect(capture.stderr.contains("Error:"))
        #expect(capture.stderr.contains("--unknown-option"))
    }

    @Test
    func jsonParseFailureIsOneDecodableValueOnStdout() throws {
        let capture = Capture()
        let code = CLIEntrypoint.run(
            arguments: ["--json", "--unknown-option"],
            output: capture.output
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(capture.stderr.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(capture.stdout.utf8))
        #expect(envelope == CLIErrorEnvelope(.usageInvalid("Unknown option '--json'")))
        #expect(capture.stdout.first == "{")
        #expect(capture.stdout.last == "}")
    }

    @Test
    func rawJsonDetectionIsExactAndStopsAtTerminator() {
        let prefix = Capture()
        let prefixCode = CLIEntrypoint.run(arguments: ["--jsonish"], output: prefix.output)
        #expect(prefixCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(prefix.stdout.isEmpty)
        #expect(prefix.stderr.isEmpty == false)

        let afterTerminator = Capture()
        let terminatorCode = CLIEntrypoint.run(
            arguments: ["--", "--json"],
            output: afterTerminator.output
        )
        #expect(terminatorCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(afterTerminator.stdout.isEmpty)
        #expect(afterTerminator.stderr.isEmpty == false)
    }

    @Test
    func helpAndVersionRemainPureTextEvenWhenRawJsonTokenIsPresent() {
        let help = Capture()
        let helpCode = CLIEntrypoint.run(arguments: ["--help", "--json"], output: help.output)
        #expect(helpCode == CLIProcessExit.success.rawValue)
        #expect(help.stderr.isEmpty)
        #expect(help.stdout.contains("USAGE:"))
        #expect((try? JSONSerialization.jsonObject(with: Data(help.stdout.utf8))) == nil)

        let version = Capture()
        let versionCode = CLIEntrypoint.run(arguments: ["--version", "--json"], output: version.output)
        #expect(versionCode == CLIProcessExit.success.rawValue)
        #expect(version.stderr.isEmpty)
        #expect(version.stdout == AppleBooksCLIVersion.current)
    }

    @Test
    func typedErrorsHaveStableCodesMessagesAndExitNumbers() throws {
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
            let code = CLIEntrypoint.presentRunError(
                error,
                jsonRequested: true,
                output: capture.output
            )
            #expect(code == expectedExit.rawValue)
            #expect(capture.stderr.isEmpty)
            let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(capture.stdout.utf8))
            #expect(envelope.error.code == expectedCode)
            #expect(envelope.error.message == error.message)
        }
    }

    @Test
    func validationErrorMapsToUsageInvalidInHumanAndJsonModes() throws {
        let human = Capture()
        let humanCode = CLIEntrypoint.presentRunError(
            ValidationError("invalid selection"),
            jsonRequested: false,
            output: human.output
        )
        #expect(humanCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(human.stdout.isEmpty)
        #expect(human.stderr == "Error: invalid selection")

        let machine = Capture()
        let machineCode = CLIEntrypoint.presentRunError(
            ValidationError("invalid selection"),
            jsonRequested: true,
            output: machine.output
        )
        #expect(machineCode == CLIProcessExit.usageInvalid.rawValue)
        #expect(machine.stderr.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(machine.stdout.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "invalid selection")
    }

    @Test
    func cleanRunExitUsesOfficialArgumentParserTextOnStdout() {
        let capture = Capture()
        let code = CLIEntrypoint.presentRunError(
            CleanExit.message("clean message"),
            jsonRequested: true,
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

        let human = Capture()
        let humanCode = CLIEntrypoint.presentRunError(
            PrivateFailure(secret: "private-payload"),
            jsonRequested: false,
            output: human.output
        )
        #expect(humanCode == CLIProcessExit.internal.rawValue)
        #expect(human.stderr == "Error: Internal error.")
        #expect(human.stderr.contains("private-payload") == false)

        let machine = Capture()
        let machineCode = CLIEntrypoint.presentRunError(
            PrivateFailure(secret: "private-payload"),
            jsonRequested: true,
            output: machine.output
        )
        #expect(machineCode == CLIProcessExit.internal.rawValue)
        #expect(machine.stderr.isEmpty)
        #expect(machine.stdout.contains("private-payload") == false)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(machine.stdout.utf8))
        #expect(envelope.error.code == .internal)
        #expect(envelope.error.message == "Internal error.")
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

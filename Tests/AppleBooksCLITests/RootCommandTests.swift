import ArgumentParser
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("RootCommandTests")
struct RootCommandTests {
    @Test
    func helpIsCleanAndDoesNotRequireOperationalState() {
        var stdout = ""
        var stderr = ""

        let code = CLIEntrypoint.run(
            arguments: ["--help"],
            output: CLIOutput(stdout: { stdout = $0 }, stderr: { stderr = $0 })
        )

        #expect(code == ExitCode.success.rawValue)
        #expect(stderr.isEmpty)
        #expect(stdout.contains("USAGE:"))
        #expect(stdout.contains("--version"))
        #expect(stdout.contains("  history "))
        #expect(stdout.contains("  skill ") == false)
    }

    @Test
    func developmentVersionDoesNotRequireOperationalState() {
        var stdout = ""
        var stderr = ""

        let code = CLIEntrypoint.run(
            arguments: ["--version"],
            output: CLIOutput(stdout: { stdout = $0 }, stderr: { stderr = $0 })
        )

        #expect(code == ExitCode.success.rawValue)
        #expect(stderr.isEmpty)
        #expect(stdout == "dev")
    }

    @Test
    func unknownInputUsesSanitizedJSONFailureWithoutOperationalState() throws {
        var stdout = ""
        var stderr = ""

        let code = CLIEntrypoint.run(
            arguments: ["unknown-command"],
            output: CLIOutput(stdout: { stdout = $0 }, stderr: { stderr = $0 })
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(stdout.isEmpty)
        #expect(stderr.contains("unknown-command") == false)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(stderr.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message == "Invalid command-line arguments.")
        #expect(envelope.error.reason == nil)
        #expect(envelope.error.recoveryHint == nil)
    }
}

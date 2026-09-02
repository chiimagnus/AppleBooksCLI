import ArgumentParser
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
    func unknownInputUsesArgumentParserFailureWithoutOperationalState() {
        var stdout = ""
        var stderr = ""

        let code = CLIEntrypoint.run(
            arguments: ["unknown-command"],
            output: CLIOutput(stdout: { stdout = $0 }, stderr: { stderr = $0 })
        )

        #expect(code == CLIProcessExit.usageInvalid.rawValue)
        #expect(stdout.isEmpty)
        #expect(stderr.contains("Error:"))
        #expect(stderr.contains("unknown-command"))
    }
}

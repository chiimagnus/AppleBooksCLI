import Darwin
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("SkillCommandTests")
struct SkillCommandTests {
    @Test
    func helpUsesLocalOptionsAndNeverExposesDatabaseGlobals() throws {
        let before = configuredTargetSnapshot()
        let installHelp = Capture()
        let installHelpCode = CLIEntrypoint.run(
            arguments: ["skill", "install", "--help"],
            output: installHelp.output
        )
        #expect(installHelpCode == 0)
        #expect(installHelp.stderr.isEmpty)
        #expect(installHelp.stdout.contains("--force"))
        #expect(installHelp.stdout.contains("--json"))
        #expect(installHelp.stdout.contains("--library-db") == false)
        #expect(installHelp.stdout.contains("--annotations-db") == false)
        #expect(installHelp.stdout.contains("--config") == false)

        let groupHelp = Capture()
        _ = CLIEntrypoint.run(arguments: ["skill"], output: groupHelp.output)
        #expect(groupHelp.stdout.contains("install") || groupHelp.stderr.contains("install"))
        #expect(configuredTargetSnapshot() == before)
    }

    @Test
    func parsedLeafAdvertisesLocalJsonToEntrypointContract() throws {
        let parsed = try AppleBooksCLI.parseAsRoot(["skill", "install", "--json"])
        let provider = try #require(parsed as? any JSONOutputProviding)
        #expect(provider.jsonRequested)
        #expect((parsed as? any GlobalOptionsProviding) == nil)
    }

    @Test
    func humanFreshInstallUsesInjectedPackagedSourceAndTemporaryCodexHome() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let command = try SkillInstallCommand.parse([])
        let capture = Capture()

        let code = run(command, installer: fixture.installer(), capture: capture)

        #expect(code == 0)
        #expect(capture.stderr.isEmpty)
        #expect(capture.stdout.contains("Installed applebookscli Skill at"))
        #expect(capture.stdout.contains(fixture.codexHome.path))
        #expect(try fixture.installedBody() == "new")
    }

    @Test
    func jsonFreshAndForceResultsRemainSingleMachineValues() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        let fresh = try SkillInstallCommand.parse(["--json"])
        let freshCapture = Capture()
        #expect(run(fresh, installer: fixture.installer(), capture: freshCapture) == 0)
        #expect(freshCapture.stderr.isEmpty)
        let freshResult = try JSONDecoder().decode(
            SkillInstallCommandResult.self,
            from: Data(freshCapture.stdout.utf8)
        )
        #expect(freshResult.installed)
        #expect(freshResult.replaced == false)
        #expect(freshResult.path.hasPrefix(fixture.codexHome.path))

        try Data("replacement".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
        let force = try SkillInstallCommand.parse(["--force", "--json"])
        let forceCapture = Capture()
        #expect(run(force, installer: fixture.installer(), capture: forceCapture) == 0)
        #expect(forceCapture.stderr.isEmpty)
        let forceResult = try JSONDecoder().decode(
            SkillInstallCommandResult.self,
            from: Data(forceCapture.stdout.utf8)
        )
        #expect(forceResult.installed)
        #expect(forceResult.replaced)
        #expect(try fixture.installedBody() == "replacement")
    }

    @Test
    func conflictUsesStableHumanAndJsonUsageErrorsWithoutLeakingPaths() throws {
        let fixture = try CommandFixture()
        defer { fixture.remove() }
        _ = try fixture.installer().install()

        let human = try SkillInstallCommand.parse([])
        let humanCapture = Capture()
        #expect(run(human, installer: fixture.installer(), capture: humanCapture) == CLIProcessExit.usageInvalid.rawValue)
        #expect(humanCapture.stdout.isEmpty)
        #expect(humanCapture.stderr.contains("already installed"))
        #expect(humanCapture.stderr.contains(fixture.root.path) == false)

        let json = try SkillInstallCommand.parse(["--json"])
        let jsonCapture = Capture()
        #expect(run(json, installer: fixture.installer(), capture: jsonCapture) == CLIProcessExit.usageInvalid.rawValue)
        #expect(jsonCapture.stderr.isEmpty)
        let envelope = try JSONDecoder().decode(CLIErrorEnvelope.self, from: Data(jsonCapture.stdout.utf8))
        #expect(envelope.error.code == .usageInvalid)
        #expect(envelope.error.message.contains("already installed"))
        #expect(envelope.error.message.contains(fixture.root.path) == false)
    }

    private func run(
        _ command: SkillInstallCommand,
        installer: SkillInstaller,
        capture: Capture
    ) -> Int32 {
        do {
            try command.run(output: capture.output, installer: installer)
            return CLIProcessExit.success.rawValue
        } catch {
            return CLIEntrypoint.presentRunError(
                error,
                jsonRequested: command.jsonRequested,
                output: capture.output
            )
        }
    }
}

private final class Capture {
    var stdout = ""
    var stderr = ""

    var output: CLIOutput {
        CLIOutput(
            stdout: { [self] in stdout += $0 },
            stderr: { [self] in stderr += $0 }
        )
    }
}

private final class CommandFixture {
    let root: URL
    let codexHome: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-skill-command-\(UUID().uuidString)", isDirectory: true)
        codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    }

    func installer() -> SkillInstaller {
        let fileManager = FileManager.default
        return SkillInstaller(
            sourceURL: source,
            environment: ["CODEX_HOME": codexHome.path],
            homeDirectory: root,
            fileOperations: SkillInstallerFileOperations(
                createDirectory: { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) },
                copyItem: fileManager.copyItem(at:to:),
                moveItem: fileManager.moveItem(at:to:),
                removeItem: fileManager.removeItem(at:),
                trashItem: fileManager.removeItem(at:)
            )
        )
    }

    func installedBody() throws -> String {
        try String(
            contentsOf: codexHome.appendingPathComponent("skills/applebookscli/SKILL.md"),
            encoding: .utf8
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct NodeSnapshot: Equatable {
    let mode: mode_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
}

private func configuredTargetSnapshot() -> NodeSnapshot? {
    let rawHome: String
    if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"], configured.isEmpty == false {
        rawHome = configured
    } else {
        rawHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .path
    }
    let target = URL(fileURLWithPath: rawHome, isDirectory: true)
        .appendingPathComponent("skills/applebookscli", isDirectory: true)
    var metadata = stat()
    guard lstat(target.path, &metadata) == 0 else { return nil }
    return NodeSnapshot(
        mode: metadata.st_mode,
        inode: metadata.st_ino,
        size: metadata.st_size,
        modifiedSeconds: metadata.st_mtimespec.tv_sec,
        modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
    )
}

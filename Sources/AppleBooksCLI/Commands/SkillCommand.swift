import ArgumentParser
import Foundation

struct SkillCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "Install the packaged applebookscli Skill.",
        subcommands: [SkillInstallCommand.self]
    )
}

struct SkillInstallCommand: ParsableCommand, CLIOutputRunnable, JSONOutputProviding {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install the packaged applebookscli Skill into Codex."
    )

    @Flag(help: "Replace an existing real-directory applebookscli Skill safely.")
    var force = false

    @Flag(help: "Emit one JSON result or error value.")
    var json = false

    var jsonRequested: Bool { json }

    mutating func run() throws {
        try run(output: .standard)
    }

    func run(output: CLIOutput) throws {
        try run(output: output, installer: nil)
    }

    func run(output: CLIOutput, installer injectedInstaller: SkillInstaller?) throws {
        let result = try execute(installer: injectedInstaller)
        let payload = SkillInstallCommandResult(
            installed: true,
            replaced: result.replaced,
            path: result.target.path
        )
        if json {
            try output.writeJSON(payload)
        } else {
            output.stdout(
                result.replaced
                    ? "Replaced applebookscli Skill at \(result.target.path)"
                    : "Installed applebookscli Skill at \(result.target.path)"
            )
        }
        if result.warnings.contains(.previousVersionBackupRetained) {
            output.stderr("Warning: the previous applebookscli Skill backup was retained for manual recovery.")
        }
    }

    func execute(installer injectedInstaller: SkillInstaller? = nil) throws -> SkillInstallationResult {
        let installer: SkillInstaller
        if let injectedInstaller {
            installer = injectedInstaller
        } else {
            let layout: InstallationLayout
            do {
                layout = try InstallationLayout.current()
            } catch {
                throw CLIError.unavailable("Packaged applebookscli Skill is unavailable.")
            }
            installer = SkillInstaller(sourceURL: layout.skillSourceURL)
        }
        return try CLIOperation.run {
            try installer.install(force: force)
        }
    }
}

struct SkillInstallCommandResult: Codable, Equatable, Sendable {
    let installed: Bool
    let replaced: Bool
    let path: String
}

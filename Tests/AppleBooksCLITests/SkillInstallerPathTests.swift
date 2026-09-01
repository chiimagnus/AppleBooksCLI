import Darwin
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("SkillInstallerPathTests")
struct SkillInstallerPathTests {
    @Test
    func installationLayoutDerivesPackagedSkillFromCanonicalPrefix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let realPrefix = root.appendingPathComponent("Cellar/applebookscli/1.0.0", isDirectory: true)
        let realBin = realPrefix.appendingPathComponent("bin", isDirectory: true)
        let realCLI = realBin.appendingPathComponent("applebookscli")
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        try Data().write(to: realCLI)

        let linkedBin = root.appendingPathComponent("prefix/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedBin, withIntermediateDirectories: true)
        let linkedCLI = linkedBin.appendingPathComponent("applebookscli")
        try FileManager.default.createSymbolicLink(at: linkedCLI, withDestinationURL: realCLI)

        let layout = try InstallationLayout(executableURL: linkedCLI)
        #expect(
            layout.skillSourceURL == realPrefix
                .appendingPathComponent("share/applebookscli/skill/applebookscli", isDirectory: true)
                .standardizedFileURL
        )
    }

    @Test
    func resolvesSafeSourceAndDefaultTargetWithoutCreatingDirectories() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let paths = try fixture.installer(environment: [:]).resolvedPaths()

        #expect(paths.source == fixture.source.resolvingSymlinksInPath())
        #expect(
            paths.codexHome.path == fixture.home
                .appendingPathComponent(".codex", isDirectory: true)
                .resolvingSymlinksInPath()
                .path
        )
        #expect(paths.skillsDirectory == paths.codexHome.appendingPathComponent("skills", isDirectory: true))
        #expect(paths.target == paths.skillsDirectory.appendingPathComponent("applebookscli", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: paths.codexHome.path) == false)

        let id = UUID(uuidString: "550E8400-E29B-41D4-A716-446655440000")!
        let staging = try paths.stagingURL(id: id)
        let backup = try paths.backupURL(id: id)
        #expect(staging.deletingLastPathComponent() == paths.skillsDirectory)
        #expect(staging.lastPathComponent == ".applebookscli-install-550e8400-e29b-41d4-a716-446655440000")
        #expect(backup.deletingLastPathComponent() == paths.skillsDirectory)
        #expect(backup.lastPathComponent == ".applebookscli-backup-550e8400-e29b-41d4-a716-446655440000")
    }

    @Test
    func resolvesExplicitCodexHomeAndSkillsSymlinksOnce() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let realCodexHome = fixture.root.appendingPathComponent("real-codex", isDirectory: true)
        let linkedCodexHome = fixture.root.appendingPathComponent("linked-codex", isDirectory: true)
        let realSkills = fixture.root.appendingPathComponent("real-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: realCodexHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: realCodexHome.appendingPathComponent("skills", isDirectory: true),
            withDestinationURL: realSkills
        )
        try FileManager.default.createSymbolicLink(at: linkedCodexHome, withDestinationURL: realCodexHome)

        let paths = try fixture.installer(environment: ["CODEX_HOME": linkedCodexHome.path]).resolvedPaths()
        #expect(paths.codexHome == realCodexHome.resolvingSymlinksInPath())
        #expect(paths.skillsDirectory == realSkills.resolvingSymlinksInPath())
        #expect(paths.target.deletingLastPathComponent() == paths.skillsDirectory)
    }

    @Test
    func rejectsSymlinkedPackagedSourceAndSkillFile() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        let linkedSource = fixture.root.appendingPathComponent("linked-source", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: fixture.source)
        #expect(throws: SkillInstallerError.packagedSourceUnsafe) {
            _ = try SkillInstaller(
                sourceURL: linkedSource,
                environment: [:],
                homeDirectory: fixture.home
            ).resolvedPaths()
        }

        let unsafeSource = fixture.root.appendingPathComponent("unsafe-source", isDirectory: true)
        try FileManager.default.createDirectory(at: unsafeSource, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: unsafeSource.appendingPathComponent("SKILL.md"),
            withDestinationURL: fixture.source.appendingPathComponent("SKILL.md")
        )
        #expect(throws: SkillInstallerError.packagedSkillUnsafe) {
            _ = try SkillInstaller(
                sourceURL: unsafeSource,
                environment: [:],
                homeDirectory: fixture.home
            ).resolvedPaths()
        }
    }

    @Test
    func rejectsRelativeCodexHomeInvalidSkillsParentAndTargetSymlink() throws {
        let fixture = try PathFixture()
        defer { fixture.remove() }
        #expect(throws: SkillInstallerError.invalidCodexHome) {
            _ = try fixture.installer(environment: ["CODEX_HOME": "relative/codex"]).resolvedPaths()
        }

        let codexWithFile = fixture.root.appendingPathComponent("codex-file-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: codexWithFile, withIntermediateDirectories: true)
        try Data().write(to: codexWithFile.appendingPathComponent("skills"))
        #expect(throws: SkillInstallerError.invalidSkillsDirectory) {
            _ = try fixture.installer(environment: ["CODEX_HOME": codexWithFile.path]).resolvedPaths()
        }

        let codexWithTarget = fixture.root.appendingPathComponent("codex-target-link", isDirectory: true)
        let skills = codexWithTarget.appendingPathComponent("skills", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("applebookscli", isDirectory: true),
            withDestinationURL: outside
        )
        #expect(throws: SkillInstallerError.unsafeTarget) {
            _ = try fixture.installer(environment: ["CODEX_HOME": codexWithTarget.path]).resolvedPaths()
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-skill-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private final class PathFixture {
    let root: URL
    let home: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-skill-installer-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: applebookscli\ndescription: fixture\n---\nbody\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
    }

    func installer(environment: [String: String]) -> SkillInstaller {
        SkillInstaller(sourceURL: source, environment: environment, homeDirectory: home)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

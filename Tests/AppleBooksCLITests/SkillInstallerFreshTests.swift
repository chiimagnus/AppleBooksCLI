import Darwin
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("SkillInstallerFreshTests")
struct SkillInstallerFreshTests {
    @Test
    func freshInstallCreatesCanonicalSkillsParentAndPublishesValidatedCopy() throws {
        let fixture = try FreshFixture()
        defer { fixture.remove() }
        let installer = fixture.installer()
        let paths = try installer.resolvedPaths()

        #expect(FileManager.default.fileExists(atPath: paths.skillsDirectory.path) == false)
        let result = try installer.install()

        #expect(result.target.path == paths.target.path)
        #expect(result.replaced == false)
        #expect(result.warnings.isEmpty)
        #expect(nodeMode(result.target) == S_IFDIR)
        let installedSkill = result.target.appendingPathComponent("SKILL.md")
        #expect(nodeMode(installedSkill) == S_IFREG)
        #expect(try Data(contentsOf: installedSkill) == Data(contentsOf: fixture.source.appendingPathComponent("SKILL.md")))
        #expect(nodeMode(fixture.source) == S_IFDIR)
        #expect(try stagingEntries(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func existingTargetConflictsBeforeCreatingOrModifyingStaging() throws {
        let fixture = try FreshFixture()
        defer { fixture.remove() }
        let installer = fixture.installer()
        let paths = try installer.resolvedPaths()
        try FileManager.default.createDirectory(at: paths.target, withIntermediateDirectories: true)
        let marker = paths.target.appendingPathComponent("marker.txt")
        try Data("existing".utf8).write(to: marker)

        #expect(throws: SkillInstallerError.targetExists) {
            _ = try installer.install()
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "existing")
        #expect(try stagingEntries(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func invalidCopiedSkillFailsClosedAndCleansOwnedStaging() throws {
        let fixture = try FreshFixture()
        defer { fixture.remove() }
        let installer = fixture.installer()
        let paths = try installer.resolvedPaths()
        try Data().write(to: fixture.source.appendingPathComponent("SKILL.md"))

        #expect(throws: SkillInstallerError.stagingUnsafe) {
            _ = try installer.install()
        }
        #expect(FileManager.default.fileExists(atPath: paths.target.path) == false)
        #expect(try stagingEntries(in: paths.skillsDirectory).isEmpty)
    }
}

private final class FreshFixture {
    let root: URL
    let home: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-skill-fresh-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: applebookscli\ndescription: fresh fixture\n---\nbody\n".utf8)
            .write(to: source.appendingPathComponent("SKILL.md"))
    }

    func installer() -> SkillInstaller {
        SkillInstaller(sourceURL: source, environment: [:], homeDirectory: home)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func nodeMode(_ url: URL) -> mode_t? {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0 else { return nil }
    return metadata.st_mode & S_IFMT
}

private func stagingEntries(in skillsDirectory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)
        .filter { $0.hasPrefix(".applebookscli-install-") }
}

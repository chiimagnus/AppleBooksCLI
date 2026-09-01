import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("SkillInstallerForceTests")
struct SkillInstallerForceTests {
    @Test
    func forceReplacesRealDirectoryAndCleansOwnedBackup() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")

        let result = try fixture.installer(fileOperations: testOperations()).install(force: true)

        #expect(result.replaced)
        #expect(result.warnings.isEmpty)
        #expect(try fixture.skillBody(at: result.target) == "new")
        #expect(try backupEntries(in: paths.skillsDirectory).isEmpty)
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func forceRejectsTargetSymlinkWithoutFollowingIt() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try FileManager.default.createDirectory(at: paths.skillsDirectory, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("marker.txt"))
        try FileManager.default.createSymbolicLink(at: paths.target, withDestinationURL: outside)

        #expect(throws: SkillInstallerError.unsafeTarget) {
            _ = try fixture.installer(fileOperations: testOperations()).install(force: true)
        }
        #expect(try String(contentsOf: outside.appendingPathComponent("marker.txt"), encoding: .utf8) == "outside")
    }

    @Test
    func forceRejectsRegularFileTargetWithoutRemovingIt() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try FileManager.default.createDirectory(at: paths.skillsDirectory, withIntermediateDirectories: true)
        try Data("user-file".utf8).write(to: paths.target)

        #expect(throws: SkillInstallerError.unsafeTarget) {
            _ = try fixture.installer(fileOperations: testOperations()).install(force: true)
        }
        #expect(try String(contentsOf: paths.target, encoding: .utf8) == "user-file")
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func stagingFailureLeavesExistingTargetUntouched() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")
        var operations = testOperations()
        operations = SkillInstallerFileOperations(
            createDirectory: operations.createDirectory,
            copyItem: { _, _ in throw InjectedFailure.failure },
            moveItem: operations.moveItem,
            removeItem: operations.removeItem,
            trashItem: operations.trashItem
        )

        #expect(throws: SkillInstallerError.installFailed) {
            _ = try fixture.installer(fileOperations: operations).install(force: true)
        }
        #expect(try fixture.skillBody(at: paths.target) == "old")
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func backupRenameFailureLeavesTargetAndCleansStaging() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")
        let base = testOperations()
        let operations = SkillInstallerFileOperations(
            createDirectory: base.createDirectory,
            copyItem: base.copyItem,
            moveItem: { source, destination in
                if source.path == paths.target.path { throw InjectedFailure.failure }
                try base.moveItem(source, destination)
            },
            removeItem: base.removeItem,
            trashItem: base.trashItem
        )

        #expect(throws: SkillInstallerError.backupFailed) {
            _ = try fixture.installer(fileOperations: operations).install(force: true)
        }
        #expect(try fixture.skillBody(at: paths.target) == "old")
        #expect(try backupEntries(in: paths.skillsDirectory).isEmpty)
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func replacementFailureRollsBackupBackWithoutDeletingOldTarget() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")
        let base = testOperations()
        let operations = SkillInstallerFileOperations(
            createDirectory: base.createDirectory,
            copyItem: base.copyItem,
            moveItem: { source, destination in
                if source.lastPathComponent.hasPrefix(".applebookscli-install-"),
                   destination.path == paths.target.path {
                    throw InjectedFailure.failure
                }
                try base.moveItem(source, destination)
            },
            removeItem: base.removeItem,
            trashItem: base.trashItem
        )

        #expect(throws: SkillInstallerError.replacementFailed) {
            _ = try fixture.installer(fileOperations: operations).install(force: true)
        }
        #expect(try fixture.skillBody(at: paths.target) == "old")
        #expect(try backupEntries(in: paths.skillsDirectory).isEmpty)
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func rollbackConflictPreservesConcurrentTargetAndOldBackup() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")
        let base = testOperations()
        let operations = SkillInstallerFileOperations(
            createDirectory: base.createDirectory,
            copyItem: base.copyItem,
            moveItem: { source, destination in
                if source.lastPathComponent.hasPrefix(".applebookscli-install-"),
                   destination.path == paths.target.path {
                    try FileManager.default.createDirectory(at: paths.target, withIntermediateDirectories: false)
                    try Data("concurrent".utf8).write(to: paths.target.appendingPathComponent("SKILL.md"))
                    throw InjectedFailure.failure
                }
                try base.moveItem(source, destination)
            },
            removeItem: base.removeItem,
            trashItem: base.trashItem
        )

        #expect(throws: SkillInstallerError.rollbackFailed) {
            _ = try fixture.installer(fileOperations: operations).install(force: true)
        }
        #expect(try fixture.skillBody(at: paths.target) == "concurrent")
        let backups = try backupEntries(in: paths.skillsDirectory)
        #expect(backups.count == 1)
        #expect(try fixture.skillBody(at: paths.skillsDirectory.appendingPathComponent(backups[0], isDirectory: true)) == "old")
        #expect(try stagingEntriesForForce(in: paths.skillsDirectory).isEmpty)
    }

    @Test
    func trashFailureReturnsWarningAndRetainsOwnedBackup() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let paths = try fixture.paths()
        try fixture.makeExistingTarget(paths.target, value: "old")
        let base = testOperations()
        let operations = SkillInstallerFileOperations(
            createDirectory: base.createDirectory,
            copyItem: base.copyItem,
            moveItem: base.moveItem,
            removeItem: base.removeItem,
            trashItem: { _ in throw InjectedFailure.failure }
        )

        let result = try fixture.installer(fileOperations: operations).install(force: true)
        #expect(result.replaced)
        #expect(result.warnings == [.previousVersionBackupRetained])
        #expect(try fixture.skillBody(at: result.target) == "new")
        let backups = try backupEntries(in: paths.skillsDirectory)
        #expect(backups.count == 1)
        #expect(try fixture.skillBody(at: paths.skillsDirectory.appendingPathComponent(backups[0], isDirectory: true)) == "old")
    }

    @Test
    func forceWorksThroughCanonicalCodexHomeAndSkillsSymlinks() throws {
        let fixture = try ForceFixture()
        defer { fixture.remove() }
        let realCodex = fixture.root.appendingPathComponent("real-codex", isDirectory: true)
        let linkedCodex = fixture.root.appendingPathComponent("linked-codex", isDirectory: true)
        let realSkills = fixture.root.appendingPathComponent("real-skills", isDirectory: true)
        try FileManager.default.createDirectory(at: realCodex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: realCodex.appendingPathComponent("skills"), withDestinationURL: realSkills)
        try FileManager.default.createSymbolicLink(at: linkedCodex, withDestinationURL: realCodex)
        let installer = SkillInstaller(
            sourceURL: fixture.source,
            environment: ["CODEX_HOME": linkedCodex.path],
            homeDirectory: fixture.home,
            fileOperations: testOperations()
        )
        let paths = try installer.resolvedPaths()
        try fixture.makeExistingTarget(paths.target, value: "old")

        let result = try installer.install(force: true)
        #expect(result.target.deletingLastPathComponent().path == realSkills.resolvingSymlinksInPath().path)
        #expect(try fixture.skillBody(at: result.target) == "new")
    }
}

private enum InjectedFailure: Error {
    case failure
}

private func testOperations() -> SkillInstallerFileOperations {
    let fileManager = FileManager.default
    return SkillInstallerFileOperations(
        createDirectory: { try fileManager.createDirectory(at: $0, withIntermediateDirectories: true) },
        copyItem: fileManager.copyItem(at:to:),
        moveItem: fileManager.moveItem(at:to:),
        removeItem: fileManager.removeItem(at:),
        trashItem: fileManager.removeItem(at:)
    )
}

private final class ForceFixture {
    let root: URL
    let home: URL
    let source: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("applebookscli-skill-force-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    }

    func installer(fileOperations: SkillInstallerFileOperations) -> SkillInstaller {
        SkillInstaller(
            sourceURL: source,
            environment: [:],
            homeDirectory: home,
            fileOperations: fileOperations
        )
    }

    func paths() throws -> SkillInstallPaths {
        try installer(fileOperations: testOperations()).resolvedPaths()
    }

    func makeExistingTarget(_ target: URL, value: String) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: target.appendingPathComponent("SKILL.md"))
    }

    func skillBody(at directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func backupEntries(in skillsDirectory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)
        .filter { $0.hasPrefix(".applebookscli-backup-") }
}

private func stagingEntriesForForce(in skillsDirectory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)
        .filter { $0.hasPrefix(".applebookscli-install-") }
}

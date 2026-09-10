import Darwin
import Foundation
import Testing
@testable import AppleBooksCLI

@Suite("InstalledPDFWorkerTests")
struct InstalledPDFWorkerTests {
    @Test
    func symlinkedBinEntryResolvesRealInstallPrefixAndWorker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let keg = root.appendingPathComponent("Cellar/applebookscli/1.0.0", isDirectory: true)
        let realBin = keg.appendingPathComponent("bin", isDirectory: true)
        let realCLI = realBin.appendingPathComponent("applebookscli")
        let worker = keg.appendingPathComponent("libexec/applebookscli/applebookscli-pdf-worker")
        try FileManager.default.createDirectory(at: realBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: realCLI)
        try Data().write(to: worker)
        #expect(chmod(worker.path, 0o700) == 0)

        let linkedBin = root.appendingPathComponent("prefix/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedBin, withIntermediateDirectories: true)
        let linkedCLI = linkedBin.appendingPathComponent("applebookscli")
        try FileManager.default.createSymbolicLink(at: linkedCLI, withDestinationURL: realCLI)

        #expect(try installedPDFWorkerURL(executableURL: linkedCLI) == worker.resolvingSymlinksInPath())
    }

    @Test
    func swiftPMProductDirectoryResolvesExecutableSibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("applebookscli")
        let worker = root.appendingPathComponent("applebookscli-pdf-worker")
        try Data().write(to: executable)
        try Data().write(to: worker)
        #expect(chmod(worker.path, 0o700) == 0)

        #expect(try installedPDFWorkerURL(executableURL: executable) == worker.standardizedFileURL)
    }

    @Test
    func sourceBuildLayoutRejectsMissingSymlinkDirectoryAndNonExecutableSibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("applebookscli")
        let worker = root.appendingPathComponent("applebookscli-pdf-worker")
        try Data().write(to: executable)

        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }

        try Data().write(to: worker)
        #expect(chmod(worker.path, 0o600) == 0)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }
        try FileManager.default.removeItem(at: worker)

        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: false)
        #expect(chmod(worker.path, 0o700) == 0)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }
        try FileManager.default.removeItem(at: worker)

        let target = root.appendingPathComponent("real-worker")
        try Data().write(to: target)
        #expect(chmod(target.path, 0o700) == 0)
        try FileManager.default.createSymbolicLink(at: worker, withDestinationURL: target)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }
    }

    @Test
    func installedBinLayoutNeverFallsBackToSameDirectorySibling() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("applebookscli")
        let sibling = bin.appendingPathComponent("applebookscli-pdf-worker")
        try Data().write(to: executable)
        try Data().write(to: sibling)
        #expect(chmod(sibling.path, 0o700) == 0)

        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }
    }

    @Test
    func rejectsRandomDirectoryWithoutSiblingAndWrongExecutableName() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("applebookscli")
        try Data().write(to: executable)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }

        let wrongName = root.appendingPathComponent("other-cli")
        let worker = root.appendingPathComponent("applebookscli-pdf-worker")
        try Data().write(to: wrongName)
        try Data().write(to: worker)
        #expect(chmod(worker.path, 0o700) == 0)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: wrongName)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

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
    func rejectsNonBinExecutableLayoutAndNeverGuessesPrefix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("applebookscli")
        try Data().write(to: executable)
        #expect(throws: CLIError.unavailable("Installed PDF worker is unavailable.")) {
            _ = try installedPDFWorkerURL(executableURL: executable)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

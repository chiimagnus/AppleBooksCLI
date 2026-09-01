import Foundation

enum InstallationLayoutError: Error, Equatable, Sendable {
    case executableUnavailable
    case invalidExecutableLocation
}

struct InstallationLayout: Equatable, Sendable {
    let executableURL: URL
    let prefixURL: URL
    let pdfWorkerURL: URL

    init(executableURL: URL) throws {
        let canonical = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let bin = canonical.deletingLastPathComponent()
        guard canonical.lastPathComponent == "applebookscli",
              bin.lastPathComponent == "bin" else {
            throw InstallationLayoutError.invalidExecutableLocation
        }
        let prefix = bin.deletingLastPathComponent()
        self.executableURL = canonical
        prefixURL = prefix
        pdfWorkerURL = prefix
            .appendingPathComponent("libexec", isDirectory: true)
            .appendingPathComponent("applebookscli", isDirectory: true)
            .appendingPathComponent("applebookscli-pdf-worker", isDirectory: false)
    }

    static func current(bundle: Bundle = .main) throws -> InstallationLayout {
        guard let executableURL = bundle.executableURL else {
            throw InstallationLayoutError.executableUnavailable
        }
        return try InstallationLayout(executableURL: executableURL)
    }

    var pdfWorkerIsExecutable: Bool {
        FileManager.default.isExecutableFile(atPath: pdfWorkerURL.path)
    }
}

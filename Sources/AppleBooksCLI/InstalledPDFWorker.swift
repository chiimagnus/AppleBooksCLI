import Foundation

func installedPDFWorkerURL(bundle: Bundle = .main) throws -> URL {
    guard let executableURL = bundle.executableURL else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }
    return try installedPDFWorkerURL(executableURL: executableURL)
}

func installedPDFWorkerURL(executableURL: URL) throws -> URL {
    let canonical = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    let bin = canonical.deletingLastPathComponent()
    guard canonical.lastPathComponent == "applebookscli",
          bin.lastPathComponent == "bin" else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }
    let worker = bin
        .deletingLastPathComponent()
        .appendingPathComponent("libexec/applebookscli/applebookscli-pdf-worker")
    guard FileManager.default.isExecutableFile(atPath: worker.path) else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }
    return worker
}

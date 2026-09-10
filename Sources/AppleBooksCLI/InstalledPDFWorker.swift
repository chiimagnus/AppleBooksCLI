import Darwin
import Foundation

func installedPDFWorkerURL(bundle: Bundle = .main) throws -> URL {
    guard let executableURL = bundle.executableURL else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }
    return try installedPDFWorkerURL(executableURL: executableURL)
}

func installedPDFWorkerURL(executableURL: URL) throws -> URL {
    let canonical = executableURL.standardizedFileURL.resolvingSymlinksInPath()
    guard canonical.lastPathComponent == "applebookscli" else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }

    let productDirectory = canonical.deletingLastPathComponent()
    let worker: URL
    if productDirectory.lastPathComponent == "bin" {
        worker = productDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("libexec/applebookscli/applebookscli-pdf-worker")
    } else {
        worker = productDirectory.appendingPathComponent("applebookscli-pdf-worker")
    }

    guard isExecutableRegularFile(worker) else {
        throw CLIError.unavailable("Installed PDF worker is unavailable.")
    }
    return worker.standardizedFileURL
}

private func isExecutableRegularFile(_ url: URL) -> Bool {
    var metadata = stat()
    guard lstat(url.path, &metadata) == 0,
          metadata.st_mode & S_IFMT == S_IFREG else {
        return false
    }
    return access(url.path, X_OK) == 0
}

import Darwin
import Foundation

enum EPUBSourceResolver {
    static func reader(for book: Book, configuration: AppleBooksConfiguration) throws -> any EPUBResourceReader {
        guard let rawPath = book.path else { throw ContentError.bookPathUnavailable }
        let currentURL = URL(fileURLWithPath: rawPath).standardizedFileURL

        let primaryError: Error
        do {
            guard currentURL.pathExtension.lowercased() == "epub" else { throw ContentError.unsupportedFormat }
            return try DirectoryEPUBResourceReader(root: currentURL)
        } catch let error as EPUBResourceError {
            throw error
        } catch let error as ContentError {
            switch error {
            case .unavailable(_), .unsupportedFormat:
                primaryError = error
            default:
                throw error
            }
        } catch {
            throw error
        }

        guard let epubRoot = configuration.epubRoot,
              let candidate = supplementalCandidate(rawPath: rawPath, root: epubRoot) else {
            throw primaryError
        }
        return try ZIPEPUBResourceReader(fileURL: candidate)
    }

    private static func supplementalCandidate(rawPath: String, root: URL) -> URL? {
        let basename = URL(fileURLWithPath: rawPath).lastPathComponent
        guard basename.isEmpty == false,
              basename.lowercased().hasSuffix(".epub") else {
            return nil
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(basename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == canonicalRoot else { return nil }

        var metadata = stat()
        guard lstat(candidate.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return candidate
    }
}

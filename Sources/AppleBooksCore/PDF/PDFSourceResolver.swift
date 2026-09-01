import Darwin
import Foundation

struct PDFSourceResolver {
    let fallbackRoot: URL

    init(fallbackRoot: URL = Self.defaultFallbackRoot) {
        self.fallbackRoot = fallbackRoot
    }

    func resolve(pdfBooks: [Book]) -> [PDFSource] {
        var booksByPath: [URL: [Book]] = [:]
        for book in pdfBooks {
            guard let rawPath = book.path,
                  let fileURL = validatedPDFURL(rawPath: rawPath) else {
                continue
            }
            booksByPath[fileURL, default: []].append(book)
        }

        var allPaths = Set(booksByPath.keys)
        allPaths.formUnion(fallbackPDFs())

        return allPaths
            .sorted { $0.path < $1.path }
            .map { fileURL in
                let matches = booksByPath[fileURL] ?? []
                let book = matches.count == 1 ? matches[0] : nil
                return PDFSource(fileURL: fileURL, book: book)
            }
    }

    private func fallbackPDFs() -> Set<URL> {
        let root = fallbackRoot.standardizedFileURL
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            return []
        }
        let canonicalRoot = root.resolvingSymlinksInPath()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: canonicalRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        return Set(entries.compactMap { validatedPDFURL(fileURL: $0) })
    }

    private func validatedPDFURL(rawPath: String) -> URL? {
        guard rawPath.hasPrefix("/") else { return nil }
        return validatedPDFURL(fileURL: URL(fileURLWithPath: rawPath))
    }

    private func validatedPDFURL(fileURL: URL) -> URL? {
        let standardized = fileURL.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "pdf" else { return nil }

        var metadata = stat()
        guard lstat(standardized.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              access(standardized.path, R_OK) == 0 else {
            return nil
        }
        return standardized.resolvingSymlinksInPath()
    }

    private static var defaultFallbackRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("iCloud~com~apple~iBooks", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
    }
}

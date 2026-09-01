import Darwin
import Foundation

struct PDFSourceResolver {
    let fallbackRoot: URL

    init(fallbackRoot: URL = Self.defaultFallbackRoot) {
        self.fallbackRoot = fallbackRoot
    }

    func resolve(pdfBooks: [Book]) -> [PDFSource] {
        let booksByPath = booksByValidatedPath(pdfBooks)
        let fallbackPaths = fallbackPDFs()
        var allPaths = Set(booksByPath.keys)
        allPaths.formUnion(fallbackPaths)

        return allPaths
            .sorted { $0.path < $1.path }
            .map {
                source(
                    fileURL: $0,
                    booksByPath: booksByPath,
                    provenance: booksByPath[$0] == nil ? .fallback : .library
                )
            }
    }

    func resolve(book: Book) -> PDFSource? {
        guard let rawPath = book.path,
              let fileURL = validatedPDFURL(rawPath: rawPath) else {
            return nil
        }
        return PDFSource(fileURL: fileURL, book: book, provenance: .library)
    }

    func resolve(fileURL: URL, pdfBooks: [Book]) -> PDFSource? {
        guard let validated = validatedPDFURL(fileURL: fileURL) else { return nil }
        let booksByPath = booksByValidatedPath(pdfBooks)
        return source(
            fileURL: validated,
            booksByPath: booksByPath,
            provenance: booksByPath[validated] == nil ? .explicit : .library
        )
    }

    private func booksByValidatedPath(_ pdfBooks: [Book]) -> [URL: [Book]] {
        var booksByPath: [URL: [Book]] = [:]
        for book in pdfBooks {
            guard let rawPath = book.path,
                  let fileURL = validatedPDFURL(rawPath: rawPath) else {
                continue
            }
            booksByPath[fileURL, default: []].append(book)
        }
        return booksByPath
    }

    private func source(
        fileURL: URL,
        booksByPath: [URL: [Book]],
        provenance: PDFSourceProvenance
    ) -> PDFSource {
        let matches = booksByPath[fileURL] ?? []
        return PDFSource(
            fileURL: fileURL,
            book: matches.count == 1 ? matches[0] : nil,
            provenance: provenance
        )
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

import Darwin
import Foundation
import SQLite3
import XCTest
@testable import AppleBooksCore

final class AppleBooksLiveSupplementalContentTests: XCTestCase {
    func testOneConfiguredSupplementalPackedEPUBCanBeRead() throws {
        guard ProcessInfo.processInfo.environment["APPLE_BOOKS_LIVE_SUPPLEMENTAL_READ"] == "1" else {
            throw XCTSkip("live supplemental Apple Books content read gate is opt-in")
        }

        let configuration = try AppleBooksConfiguration.loadDefault()
        guard let supplementalRoot = configuration.epubRoot else {
            throw XCTSkip("no configured supplemental EPUB root")
        }

        let discovered = try DatabaseDiscovery().discover()
        let library = try SQLiteConnection.readOnly(path: discovered.libraryDB.path)
        let books: [Book]
        do {
            guard sqlite3_db_readonly(library.handle, "main") == 1 else {
                throw LiveSupplementalContentGateError.libraryNotReadOnly
            }
            books = try BookQueries(connection: library).list()
            try library.close()
        } catch {
            try? library.close()
            throw error
        }

        guard let candidate = try books
            .sorted(by: { $0.localPK < $1.localPK })
            .first(where: { try Self.isEligibleForPackedFallback($0, supplementalRoot: supplementalRoot) }) else {
            throw XCTSkip("no eligible configured supplemental packed EPUB sample")
        }

        let reader = try EPUBSourceResolver.reader(for: candidate, configuration: configuration)
        guard reader is ZIPEPUBResourceReader else {
            throw LiveSupplementalContentGateError.resolverDidNotUsePackedSource
        }

        let content = try BookContent(reader: reader)
        let chapters = try content.listChapters()
        guard let chapter = chapters.sorted(by: {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }).first else {
            throw XCTSkip("eligible packed EPUB has no readable chapter")
        }
        _ = try content.getChapter(chapter.id)
        XCTAssertGreaterThan(chapter.order, 0)
        XCTAssertFalse(chapter.href.isEmpty)
    }

    private static func isEligibleForPackedFallback(_ book: Book, supplementalRoot: URL) throws -> Bool {
        guard let rawPath = book.path else { return false }
        let primary = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard primary.pathExtension.lowercased() == "epub" else { return false }

        do {
            _ = try DirectoryEPUBResourceReader(root: primary)
            return false
        } catch is EPUBResourceError {
            return false
        } catch let error as ContentError {
            switch error {
            case .unavailable(_), .unsupportedFormat:
                break
            default:
                return false
            }
        }

        let root = supplementalRoot.standardizedFileURL.resolvingSymlinksInPath()
        let basename = primary.lastPathComponent
        guard basename.isEmpty == false else { return false }
        let packed = root.appendingPathComponent(basename, isDirectory: false).standardizedFileURL
        guard packed.deletingLastPathComponent() == root else { return false }

        var metadata = stat()
        return lstat(packed.path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFREG
    }
}

private enum LiveSupplementalContentGateError: Error {
    case libraryNotReadOnly
    case resolverDidNotUsePackedSource
}

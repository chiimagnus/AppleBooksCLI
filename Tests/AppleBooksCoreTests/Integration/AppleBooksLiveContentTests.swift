import Darwin
import SQLite3
import XCTest
@testable import AppleBooksCore

final class AppleBooksLiveContentTests: XCTestCase {
    func testOneEligibleLocalEPUBCanBeReadWithoutIdentityEvidence() throws {
        guard ProcessInfo.processInfo.environment["APPLE_BOOKS_LIVE_CONTENT_READ"] == "1" else {
            throw XCTSkip("live Apple Books content read gate is opt-in")
        }

        let verified: Bool
        do {
            verified = try runLiveContentGate()
        } catch {
            XCTFail("live Apple Books content read gate failed")
            return
        }
        guard verified else {
            throw XCTSkip("no eligible local EPUB sample")
        }
    }

    private func runLiveContentGate() throws -> Bool {
        let discovered = try DatabaseDiscovery().discover()
        let library = try SQLiteConnection.readOnly(path: discovered.libraryDB.path)
        let books: [Book]
        do {
            guard sqlite3_db_readonly(library.handle, "main") == 1 else {
                throw LiveContentGateError.libraryNotReadOnly
            }
            books = try BookQueries(connection: library).list()
            try library.close()
        } catch {
            try? library.close()
            throw error
        }

        var inspectedCandidates = 0
        for book in books.sorted(by: { $0.localPK < $1.localPK }) {
            guard let rawPath = book.path else { continue }
            let root = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard root.pathExtension.lowercased() == "epub" else { continue }

            var metadata = stat()
            guard lstat(root.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR,
                  BookContentAvailability.inspect(root) == .available else {
                continue
            }

            inspectedCandidates += 1
            guard inspectedCandidates <= 32 else { break }

            let content: BookContent
            do {
                content = try BookContent(root: root)
            } catch {
                continue
            }

            do {
                let chapters = try content.listChapters()
                guard let chapter = chapters.sorted(by: {
                    $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
                }).first else {
                    continue
                }
                _ = try content.getChapter(chapter.id)
                XCTAssertGreaterThan(chapter.order, 0)
                XCTAssertFalse(chapter.href.isEmpty)
                return true
            } catch is EPUBPathError {
                continue
            } catch ContentError.unavailable(_) {
                continue
            } catch DirectoryEPUBPackageError.readFailed {
                continue
            }
        }
        return false
    }
}

private enum LiveContentGateError: Error {
    case libraryNotReadOnly
}

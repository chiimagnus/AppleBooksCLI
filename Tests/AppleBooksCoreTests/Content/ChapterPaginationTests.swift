import Foundation
import Testing
import ZIPFoundation
@testable import AppleBooksCore

@Suite("ChapterPaginationTests")
struct ChapterPaginationTests {
    @Test
    func pagesByExtendedGraphemeClustersWithoutSplittingVisibleCharacters() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.epub)

        let page = try content.chapterPage(id: "unicode", offset: 1, maxCharacters: 2)
        #expect(page.content == "🇸🇬e\u{301}")
        #expect(page.offset == 1)
        #expect(page.endOffset == 3)
        #expect(page.totalCharacters == 6)
        #expect(page.hasMore)
        #expect(page.nextOffset == 3)

        let remainder = try content.chapterPage(id: "unicode", offset: 3, maxCharacters: nil)
        #expect(remainder.content == "中🙂Z")
        #expect(remainder.offset == 3)
        #expect(remainder.endOffset == 6)
        #expect(remainder.totalCharacters == 6)
        #expect(remainder.hasMore == false)
        #expect(remainder.nextOffset == nil)
    }

    @Test
    func normalizesNegativeOffsetAndRejectsInvalidBounds() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.epub)

        let first = try content.chapterPage(id: "unicode", offset: -100, maxCharacters: 2)
        #expect(first.content == "A🇸🇬")
        #expect(first.offset == 0)
        #expect(first.nextOffset == 2)

        #expect(throws: BookContentError.invalidMaximumCharacters) {
            _ = try content.chapterPage(id: "unicode", maxCharacters: 0)
        }
        #expect(throws: BookContentError.invalidMaximumCharacters) {
            _ = try content.chapterPage(id: "unicode", maxCharacters: -1)
        }
        #expect(throws: BookContentError.chapterOffsetOutOfRange(offset: 6, total: 6)) {
            _ = try content.chapterPage(id: "unicode", offset: 6)
        }
        #expect(throws: BookContentError.chapterOffsetOutOfRange(offset: Int.max, total: 6)) {
            _ = try content.chapterPage(id: "unicode", offset: Int.max, maxCharacters: Int.max)
        }
    }

    @Test
    func defaultCapAndHugeCapHaveStableContinuationMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.epub)

        let first = try content.chapterPage(id: "long")
        #expect(first.content.count == 10_000)
        #expect(first.offset == 0)
        #expect(first.endOffset == 10_000)
        #expect(first.totalCharacters == 10_002)
        #expect(first.hasMore)
        #expect(first.nextOffset == 10_000)

        let rest = try content.chapterPage(id: "long", offset: 10_000, maxCharacters: Int.max)
        #expect(rest.content == "aa")
        #expect(rest.endOffset == 10_002)
        #expect(rest.hasMore == false)
        #expect(rest.nextOffset == nil)
    }

    @Test
    func orderOnlyContinuationDoesNotLetNumericRawIDCaptureAnotherChapterOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"2\" href=\"raw.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"target\" href=\"target.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"2\"/><itemref idref=\"target\"/></spine></package>".utf8)
            .write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body>raw numeric id</body></html>".utf8).write(to: root.appendingPathComponent("OPS/raw.xhtml"))
        try Data("<html><body>order two</body></html>".utf8).write(to: root.appendingPathComponent("OPS/target.xhtml"))

        let content = try BookContent(root: root)
        #expect(try content.getChapter("2") == "raw numeric id")
        let ordered = try content.resolveChapter(order: 2)
        #expect(ordered.id == "target")
        let page = try content.continuationPage(
            chapter: ordered,
            offset: 0,
            maximumGraphemes: 100,
            maximumUTF8Bytes: 1_024
        )
        #expect(page.content == "order two")
    }

    @Test
    func chapterCursorGenerationStalesOnDirectoryResourceEditAndZipReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.epub)
        let chapter = try content.resolveChapter(order: 2)
        let fingerprint = try Self.chapterFingerprint()
        let directoryGeneration = try CursorGeneration.compose([
            content.chapterCursorGenerationComponent(for: chapter),
        ])
        let directoryCursor = try CursorPaginationSession(
            cursor: nil,
            fingerprint: fingerprint,
            generation: directoryGeneration
        ).nextCursor(
            after: directoryGeneration,
            hasMore: true,
            locator: try CursorLocator(words: [1])
        )
        try Data("<html><body>changed directory body with different size</body></html>".utf8)
            .write(to: fixture.epub.appendingPathComponent("OPS/long.xhtml"))
        let changedDirectoryGeneration = try CursorGeneration.compose([
            content.chapterCursorGenerationComponent(for: chapter),
        ])
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try CursorPaginationSession(
                cursor: directoryCursor,
                fingerprint: fingerprint,
                generation: changedDirectoryGeneration
            )
        }

        let listGeneration = try CursorGeneration.compose([
            content.chapterListCursorGenerationComponent(),
        ])
        let listCursor = try CursorPaginationSession(
            cursor: nil,
            fingerprint: fingerprint,
            generation: listGeneration
        ).nextCursor(
            after: listGeneration,
            hasMore: true,
            locator: try CursorLocator(words: [1])
        )
        let packageURL = fixture.epub.appendingPathComponent("OPS/package.opf")
        var packageData = try Data(contentsOf: packageURL)
        packageData.append(Data("\n<!-- changed package metadata -->".utf8))
        try packageData.write(to: packageURL)
        let changedListGeneration = try CursorGeneration.compose([
            content.chapterListCursorGenerationComponent(),
        ])
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try CursorPaginationSession(
                cursor: listCursor,
                fingerprint: fingerprint,
                generation: changedListGeneration
            )
        }

        let zipURL = fixture.root.appendingPathComponent("supplemental.epub")
        try Self.makeZipEPUB(at: zipURL, body: "first zip body")
        let zipContent = try BookContent(reader: ZIPEPUBResourceReader(fileURL: zipURL))
        let zipChapter = try zipContent.resolveChapter(order: 1)
        let zipGeneration = try CursorGeneration.compose([
            zipContent.chapterCursorGenerationComponent(for: zipChapter),
        ])
        let zipCursor = try CursorPaginationSession(
            cursor: nil,
            fingerprint: fingerprint,
            generation: zipGeneration
        ).nextCursor(
            after: zipGeneration,
            hasMore: true,
            locator: try CursorLocator(words: [1])
        )
        let zipListGeneration = try CursorGeneration.compose([
            zipContent.chapterListCursorGenerationComponent(),
        ])
        let zipListCursor = try CursorPaginationSession(
            cursor: nil,
            fingerprint: fingerprint,
            generation: zipListGeneration
        ).nextCursor(
            after: zipListGeneration,
            hasMore: true,
            locator: try CursorLocator(words: [1])
        )
        try FileManager.default.removeItem(at: zipURL)
        try Self.makeZipEPUB(at: zipURL, body: "replacement zip body with a different size")
        let changedZipGeneration = try CursorGeneration.compose([
            zipContent.chapterCursorGenerationComponent(for: zipChapter),
        ])
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try CursorPaginationSession(
                cursor: zipCursor,
                fingerprint: fingerprint,
                generation: changedZipGeneration
            )
        }
        let changedZipListGeneration = try CursorGeneration.compose([
            zipContent.chapterListCursorGenerationComponent(),
        ])
        #expect(throws: CursorPaginationError.staleCursor) {
            _ = try CursorPaginationSession(
                cursor: zipListCursor,
                fingerprint: fingerprint,
                generation: changedZipListGeneration
            )
        }
    }

    @Test
    func imageOnlyChapterReturnsLegalEmptyPage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.epub)

        let page = try content.chapterPage(id: "empty", offset: 999, maxCharacters: 10)
        #expect(page == ChapterPage(
            content: "",
            offset: 0,
            endOffset: 0,
            totalCharacters: 0,
            hasMore: false,
            nextOffset: nil
        ))
    }

    private static func chapterFingerprint() throws -> CursorQueryFingerprint {
        try CursorQueryFingerprint.make(
            kind: "content.chapter.test",
            fields: [CursorFingerprintField("version", .unsigned(1))]
        )
    }

    private static func makeZipEPUB(at url: URL, body: String) throws {
        let resources: [String: Data] = [
            "META-INF/container.xml": Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8),
            "OPS/package.opf": Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"chapter\"/></spine></package>".utf8),
            "OPS/chapter.xhtml": Data("<html><body>\(body)</body></html>".utf8),
        ]
        let archive = try Archive(url: url, accessMode: .create)
        for (path, data) in resources.sorted(by: { $0.key < $1.key }) {
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return start < end ? data.subdata(in: start..<end) : Data()
            }
        }
    }

    private final class Fixture {
        let root: URL
        let epub: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            epub = root.appendingPathComponent("pagination.epub")
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)

            try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
                .write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try Data("<package xmlns=\"http://www.idpf.org/2007/opf\"><manifest><item id=\"unicode\" href=\"unicode.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"long\" href=\"long.xhtml\" media-type=\"application/xhtml+xml\"/><item id=\"empty\" href=\"empty.xhtml\" media-type=\"application/xhtml+xml\"/></manifest><spine><itemref idref=\"unicode\"/><itemref idref=\"long\"/><itemref idref=\"empty\"/></spine></package>".utf8)
                .write(to: epub.appendingPathComponent("OPS/package.opf"))
            try Data("<html><body>A🇸🇬e\u{301}中🙂Z</body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/unicode.xhtml"))
            try Data("<html><body>\(String(repeating: "a", count: 10_002))</body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/long.xhtml"))
            try Data("<html><body><img src=\"image.jpg\"/></body></html>".utf8)
                .write(to: epub.appendingPathComponent("OPS/empty.xhtml"))
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

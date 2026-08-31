import Foundation
import Testing
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

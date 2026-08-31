import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ContentParityRegressionTests")
struct ContentParityRegressionTests {
    @Test
    func navFixtureKeepsCombinedContentContract() throws {
        let root = fixture("Nav.epub")
        #expect(BookContentAvailability.inspect(root) == .available)

        let content = try BookContent(root: root)
        #expect(try EPUBEncryption.inspect(package: content.package) == .fontObfuscationOnly)
        #expect(try content.listChapters() == [
            Chapter(id: "1", title: "One", href: "OPS/Text/shared.xhtml", fragment: "one", order: 1, depth: 0),
            Chapter(id: "2", title: "Two", href: "OPS/Text/shared.xhtml", fragment: "two", order: 2, depth: 1),
            Chapter(id: "chapter-two", title: "Three", href: "OPS/Text/chapter-two.xhtml", fragment: "", order: 3, depth: 1),
        ])

        #expect(try content.getChapter("1") == "First & 😀\n\n你好世界")
        #expect(try content.getChapter("2") == "Second section\n\nTail line")
        #expect(try content.getChapter("3") == "Context anchor line\n\nSecond paragraph 😀")
        #expect(try content.getChapter("raw") == "Raw spine only\n\nCJK你好😀")

        let current = try CurrentReadingChapter.resolve(chapterID: "chapter-two", in: content)
        #expect(current?.order == 3)

        let location = Location(rawCFI: "epubcfi(/6/8[chapter-two]!/4/2[text],:3,:9)")
        #expect(location.chapterID == "chapter-two")
        #expect(location.characterRange == .init(start: 3, end: 9))

        let context = try AnnotationContextMatcher.match(
            chapterText: try content.getChapter("chapter-two"),
            anchor: "Context\tanchor",
            charsBefore: 0,
            charsAfter: 5
        )
        #expect(context.matched == "Context anchor")

        let shared = try Data(contentsOf: root.appendingPathComponent("OPS/Text/shared.xhtml"))
        #expect(throws: XHTMLTextError.fragmentNotFound) {
            _ = try XHTMLText.extract(shared, fragment: "missing")
        }
        #expect(throws: EPUBPathError.rootEscape) {
            _ = try EPUBPath.resolve(root: root, reference: "../../outside.xhtml")
        }
    }

    @Test
    func ncxFixtureKeepsFallbackOrderingAndDepth() throws {
        let content = try BookContent(root: fixture("NCX.epub"))
        #expect(try content.listChapters() == [
            Chapter(id: "n1", title: "NCX One", href: "OPS/Text/one.xhtml", fragment: "part", order: 1, depth: 0),
            Chapter(id: "n2", title: "NCX Two", href: "OPS/Text/two.xhtml", fragment: "", order: 2, depth: 1),
        ])
        #expect(try content.getChapter("n1") == "NCX first")
        #expect(try content.getChapter("2") == "NCX second")
    }

    @Test
    func spineFixtureKeepsSyntheticFallbackAndSelectors() throws {
        let content = try BookContent(root: fixture("Spine.epub"))
        #expect(try content.listChapters() == [
            Chapter(id: "alpha", title: "Section 1", href: "OPS/Text/alpha.xhtml", fragment: "", order: 1, depth: 0),
            Chapter(id: "beta", title: "Section 2", href: "OPS/Text/beta.xhtml", fragment: "", order: 2, depth: 0),
        ])
        #expect(try content.getChapter("alpha") == "Alpha body")
        #expect(try content.getChapter("2") == "Beta body")
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/EPUBParity/\(name)", isDirectory: true)
    }
}

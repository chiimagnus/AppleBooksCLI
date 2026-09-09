import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ChapterTextTests")
struct ChapterTextTests {
    @Test
    func wholeBodyPreservesParagraphsInlineAdjacencyAndVisibleTextOnly() throws {
        let data = Data("""
        <html><head><title>hidden title</title><style>.x{}</style></head><body>
          <p>Hello <em>world</em> &amp; 😀</p>
          <div>你好<span>世界</span><br/>下一行</div>
          <script>hidden script</script>
        </body></html>
        """.utf8)

        #expect(try XHTMLText.extract(data, fragment: nil) == "Hello world & 😀\n\n你好世界\n下一行")
    }

    @Test
    func fragmentStopsAtFirstLaterSiblingAnchorInDocumentOrder() throws {
        let data = Data("""
        <html><body>
          <a id="one"></a><section><p>第一段 😀</p><div>nested <b>text</b></div></section>
          <div><a id="two"></a><p>第二段</p></div>
          <a id="three"></a><p>第三段</p>
        </body></html>
        """.utf8)

        #expect(try XHTMLText.extract(data, fragment: "one", stopFragments: ["two", "three"]) == "第一段 😀\n\nnested text")
        #expect(try XHTMLText.extract(data, fragment: "two", stopFragments: ["one", "three"]) == "第二段")
    }

    @Test
    func missingFragmentFailsInsteadOfReturningWholeFile() throws {
        let data = Data("<html><body><p>whole file</p></body></html>".utf8)
        #expect(throws: XHTMLTextError.fragmentNotFound) {
            _ = try XHTMLText.extract(data, fragment: "missing")
        }
    }

    @Test
    func traversalBudgetsAcceptBoundaryAndRejectNextDepthOrNode() throws {
        let boundaryDepth = Data(("<html><body>" + String(repeating: "<div>", count: 255) + String(repeating: "</div>", count: 255) + "</body></html>").utf8)
        #expect(try XHTMLText.extract(boundaryDepth, fragment: nil).isEmpty)
        #expect(try XHTMLText.page(
            boundaryDepth,
            fragment: nil,
            offset: 0,
            maximumGraphemes: 1,
            maximumUTF8Bytes: 8
        ).content.isEmpty)

        let overflowDepth = Data(("<html><body>" + String(repeating: "<div>", count: 256) + String(repeating: "</div>", count: 256) + "</body></html>").utf8)
        #expect(throws: EPUBResourceError.tooComplex) {
            _ = try XHTMLText.extract(overflowDepth, fragment: nil)
        }
        #expect(throws: EPUBResourceError.tooComplex) {
            _ = try XHTMLText.page(
                overflowDepth,
                fragment: nil,
                offset: 0,
                maximumGraphemes: 1,
                maximumUTF8Bytes: 8
            )
        }

        let boundaryNodes = Data(("<html><body>" + String(repeating: "<span></span>", count: EPUBStructureBudget.maximumXHTMLNodes - 1) + "</body></html>").utf8)
        #expect(try XHTMLText.extract(boundaryNodes, fragment: nil).isEmpty)
        #expect(try XHTMLText.page(
            boundaryNodes,
            fragment: nil,
            offset: 0,
            maximumGraphemes: 1,
            maximumUTF8Bytes: 8
        ).content.isEmpty)

        let overflowNodes = Data(("<html><body>" + String(repeating: "<span></span>", count: EPUBStructureBudget.maximumXHTMLNodes) + "</body></html>").utf8)
        #expect(throws: EPUBResourceError.tooComplex) {
            _ = try XHTMLText.extract(overflowNodes, fragment: nil)
        }
        #expect(throws: EPUBResourceError.tooComplex) {
            _ = try XHTMLText.page(
                overflowNodes,
                fragment: nil,
                offset: 0,
                maximumGraphemes: 1,
                maximumUTF8Bytes: 8
            )
        }
    }

    @Test
    func boundedPagesRecomposeExactNormalizedTextAcrossWhitespaceBoundaries() throws {
        let data = Data("""
        <html><body><p>Hello <em>world</em></p><div>你好<br/>下一行</div><p>Tail 😀</p></body></html>
        """.utf8)
        let full = try XHTMLText.extract(data, fragment: nil)
        var offset = 0
        var recomposed = ""
        while true {
            let page = try XHTMLText.page(
                data,
                fragment: nil,
                offset: offset,
                maximumGraphemes: 3,
                maximumUTF8Bytes: 32
            )
            recomposed += page.content
            if page.hasMore == false { break }
            #expect(page.returnedGraphemes > 0)
            offset += page.returnedGraphemes
        }
        #expect(recomposed == full)
    }

    @Test
    func boundedTraversalStopsAfterSuccessorEvidenceAndKeepsPageMemoryBounded() throws {
        let sourceCharacterCount = 20 * 1_024 * 1_024
        let data = Data(("<html><body><p>" + String(repeating: "a", count: sourceCharacterCount) + "</p></body></html>").utf8)
        let page = try XHTMLText.page(
            data,
            fragment: nil,
            offset: 0,
            maximumGraphemes: ChapterContinuationPolicy.defaultMaximumCharacters,
            maximumUTF8Bytes: ChapterContinuationPolicy.defaultMaximumUTF8Bytes
        )
        #expect(page.returnedGraphemes == ChapterContinuationPolicy.defaultMaximumCharacters)
        #expect(page.content.count == ChapterContinuationPolicy.defaultMaximumCharacters)
        #expect(page.content.utf8.count <= ChapterContinuationPolicy.defaultMaximumUTF8Bytes)
        #expect(page.hasMore)
        #expect(page.inspectedSourceGraphemes == ChapterContinuationPolicy.defaultMaximumCharacters + 1)
        #expect(page.inspectedSourceGraphemes < sourceCharacterCount)

        let family = "👨‍👩‍👧‍👦"
        let byteLimitedData = Data(("<html><body>" + String(repeating: family, count: 10_000) + "</body></html>").utf8)
        let byteLimited = try XHTMLText.page(
            byteLimitedData,
            fragment: nil,
            offset: 0,
            maximumGraphemes: ChapterContinuationPolicy.maximumCharacters,
            maximumUTF8Bytes: ChapterContinuationPolicy.maximumUTF8Bytes
        )
        #expect(byteLimited.returnedGraphemes < ChapterContinuationPolicy.maximumCharacters)
        #expect(byteLimited.content.utf8.count <= ChapterContinuationPolicy.maximumUTF8Bytes)
        #expect(byteLimited.hasMore)
        #expect(byteLimited.inspectedSourceGraphemes == byteLimited.returnedGraphemes + 1)
    }

    @Test
    func bookContentUsesSameFileFragmentsAndRawSpineCanStillReadWholeBody() throws {
        let root = try makeEPUB()
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try BookContent(root: root)

        #expect(try content.getChapter("1") == "First & 😀")
        #expect(try content.getChapter("2") == "Second\n\nTail")
        #expect(try content.getChapter("chapter") == "First & 😀\n\nSecond\n\nTail")
    }

    private func makeEPUB() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"><manifest>
          <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
        </manifest><spine><itemref idref="chapter"/></spine></package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("""
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol>
            <li><a href="chapter.xhtml#one">One</a></li>
            <li><a href="chapter.xhtml#two">Two</a></li>
          </ol></nav>
        </body></html>
        """.utf8).write(to: root.appendingPathComponent("OPS/nav.xhtml"))
        try Data("""
        <html><body><a id="one"></a><p>First &amp; 😀</p><a id="two"></a><p>Second</p><p>Tail</p></body></html>
        """.utf8).write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
        return root
    }
}

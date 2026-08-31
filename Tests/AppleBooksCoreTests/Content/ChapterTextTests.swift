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

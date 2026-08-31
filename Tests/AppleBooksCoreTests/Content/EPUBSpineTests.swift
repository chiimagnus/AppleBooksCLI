import Foundation
import Testing
@testable import AppleBooksCore

@Suite("EPUBSpineTests")
struct EPUBSpineTests {
    @Test
    func spineFallbackProducesStableSyntheticChapters() throws {
        let root = try makeEPUB(nav: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try BookContent(root: root)

        #expect(try content.listChapters() == [
            Chapter(id: "2", title: "Section 1", href: "OPS/Text/first.xhtml", fragment: "", order: 1, depth: 0),
            Chapter(id: "second", title: "Section 2", href: "OPS/Text/second.xhtml", fragment: "", order: 2, depth: 0),
        ])
    }

    @Test
    func selectorPrefersRealIDThenOrderThenRawSpineEntry() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body>
          <nav epub:type="toc"><ol><li><a href="Text/first.xhtml">First</a></li></ol></nav>
        </body></html>
        """
        let root = try makeEPUB(nav: nav)
        defer { try? FileManager.default.removeItem(at: root) }
        let content = try BookContent(root: root)

        let idMatch = try content.resolveChapter("2")
        #expect(idMatch.href == "OPS/Text/first.xhtml")
        let rawSpine = try content.resolveChapter("second")
        #expect(rawSpine.href == "OPS/Text/second.xhtml")
        #expect(String(decoding: try content.readChapterBytes(rawSpine), as: UTF8.self).contains("second-body"))
        #expect(throws: BookContentError.chapterNotFound) { _ = try content.resolveChapter("missing") }
    }

    private func makeEPUB(nav: String?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Text"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
          <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        var manifest = """
          <item id="2" href="Text/first.xhtml" media-type="application/xhtml+xml"/>
          <item id="second" href="Text/second.xhtml" media-type="application/xhtml+xml"/>
        """
        if nav != nil { manifest += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>" }
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"><manifest>\(manifest)</manifest>
          <spine><itemref idref="2"/><itemref idref="second"/></spine>
        </package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        if let nav { try Data(nav.utf8).write(to: root.appendingPathComponent("OPS/nav.xhtml")) }
        try Data("<html><body>first-body</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/first.xhtml"))
        try Data("<html><body>second-body</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/second.xhtml"))
        return root
    }
}

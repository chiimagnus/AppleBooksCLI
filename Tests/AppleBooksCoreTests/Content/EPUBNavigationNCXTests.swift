import Foundation
import Testing
@testable import AppleBooksCore

@Suite("EPUBNavigationNCXTests")
struct EPUBNavigationNCXTests {
    @Test
    func fallsBackToMediaTypeNCXAndUsesNCXDirectoryAsBase() throws {
        let root = try makeEPUB(nav: nil, ncx: """
        <?xml version="1.0"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/">
          <navMap>
            <navPoint id="dup"><navLabel><text>One</text></navLabel><content src="../Text/ch1.xhtml#one"/>
              <navPoint id="dup"><navLabel><text>Two</text></navLabel><content src="../Text/ch1.xhtml#two"/></navPoint>
            </navPoint>
            <navPoint id="three"><navLabel><text>Three</text></navLabel><content src="../Text/ch2.xhtml"/></navPoint>
          </navMap>
        </ncx>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let chapters = try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).chaptersFromNavigation()
        #expect(chapters == [
            Chapter(id: "1", title: "One", href: "OPS/Text/ch1.xhtml", fragment: "one", order: 1, depth: 0),
            Chapter(id: "2", title: "Two", href: "OPS/Text/ch1.xhtml", fragment: "two", order: 2, depth: 1),
            Chapter(id: "three", title: "Three", href: "OPS/Text/ch2.xhtml", fragment: "", order: 3, depth: 0),
        ])
    }

    @Test
    func usableNavWinsWithoutMixingNCX() throws {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol><li><a href="Text/ch1.xhtml">Nav</a></li></ol></nav></body>
        </html>
        """
        let root = try makeEPUB(nav: nav, ncx: """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="ncx"><navLabel><text>NCX</text></navLabel><content src="../Text/ch2.xhtml"/></navPoint>
        </navMap></ncx>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let chapters = try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).chaptersFromNavigation()
        #expect(chapters.map(\.title) == ["Nav"])
    }

    @Test
    func malformedMissingNavMapOrIncompletePointFallsThroughAsEmpty() throws {
        let cases = [
            "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"><navMap>",
            "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"></ncx>",
            "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"><navMap><navPoint id=\"x\"><navLabel><text>X</text></navLabel></navPoint></navMap></ncx>",
        ]
        for ncx in cases {
            let root = try makeEPUB(nav: nil, ncx: ncx)
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).chaptersFromNavigation().isEmpty)
        }
    }

    @Test
    func unsafeNCXSourcePropagatesPathFailure() throws {
        let root = try makeEPUB(nav: nil, ncx: """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="x"><navLabel><text>X</text></navLabel><content src="../../../outside.xhtml"/></navPoint>
        </navMap></ncx>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: EPUBPathError.rootEscape) {
            _ = try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).chaptersFromNavigation()
        }
    }

    private func makeEPUB(nav: String?, ncx: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Text"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Navigation"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
          <rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/>
        </rootfiles></container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))

        var manifest = """
        <item id="ncx" href="Navigation/book.ncx" media-type="application/x-dtbncx+xml"/>
        <item id="ch1" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
        <item id="ch2" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
        """
        if nav != nil {
            manifest += "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        }
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf"><manifest>\(manifest)</manifest>
          <spine><itemref idref="ch1"/><itemref idref="ch2"/></spine>
        </package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data(ncx.utf8).write(to: root.appendingPathComponent("OPS/Navigation/book.ncx"))
        if let nav { try Data(nav.utf8).write(to: root.appendingPathComponent("OPS/nav.xhtml")) }
        try Data("<html><body>one</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/ch1.xhtml"))
        try Data("<html><body>two</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/ch2.xhtml"))
        return root
    }
}

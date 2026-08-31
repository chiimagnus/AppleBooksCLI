import Foundation
import Testing
@testable import AppleBooksCore

@Suite("EPUBNavigationNavTests")
struct EPUBNavigationNavTests {
    @Test
    func parsesNestedTocDeduplicatesAndFallsBackForSharedManifestItem() throws {
        let root = try makeEPUB(nav: """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body>
            <nav epub:type="landmarks"><ol><li><a href="ignored.xhtml">Ignored</a></li></ol></nav>
            <nav epub:type="page-list toc">
              <ol>
                <li><a href="Text/ch1.xhtml#one">One</a>
                  <ol>
                    <li><a href="Text/ch1.xhtml#two">Two</a></li>
                    <li><a href="Text/ch2.xhtml">Three</a></li>
                    <li><a href="Text/ch2.xhtml">Duplicate</a></li>
                  </ol>
                </li>
              </ol>
            </nav>
          </body>
        </html>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let chapters = try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).navChapters()
        #expect(chapters == [
            Chapter(id: "1", title: "One", href: "OPS/Text/ch1.xhtml", fragment: "one", order: 1, depth: 0),
            Chapter(id: "2", title: "Two", href: "OPS/Text/ch1.xhtml", fragment: "two", order: 2, depth: 1),
            Chapter(id: "chapter-two", title: "Three", href: "OPS/Text/ch2.xhtml", fragment: "", order: 3, depth: 1),
        ])
    }

    @Test
    func missingTocNavFallsBackToEmpty() throws {
        let root = try makeEPUB(nav: """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="landmarks"><ol><li><a href="Text/ch1.xhtml">Landmark</a></li></ol></nav></body>
        </html>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).navChapters().isEmpty)
    }

    @Test
    func escapedNavHrefIsRejected() throws {
        let root = try makeEPUB(nav: """
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
          <body><nav epub:type="toc"><ol><li><a href="../../../outside.xhtml">Bad</a></li></ol></nav></body>
        </html>
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: EPUBPathError.rootEscape) {
            _ = try EPUBNavigation(package: DirectoryEPUBPackage(root: root)).navChapters()
        }
    }

    private func makeEPUB(nav: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS/Text"), withIntermediateDirectories: true)
        try Data("""
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.utf8).write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="cover-image nav"/>
            <item id="chapter-one" href="Text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="chapter-two" href="Text/ch2.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter-one"/><itemref idref="chapter-two"/></spine>
        </package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data(nav.utf8).write(to: root.appendingPathComponent("OPS/nav.xhtml"))
        try Data("<html><body>one</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/ch1.xhtml"))
        try Data("<html><body>two</body></html>".utf8).write(to: root.appendingPathComponent("OPS/Text/ch2.xhtml"))
        return root
    }
}

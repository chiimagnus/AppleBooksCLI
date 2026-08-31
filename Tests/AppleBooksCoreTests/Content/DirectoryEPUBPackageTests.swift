import Foundation
import Testing
@testable import AppleBooksCore

@Suite("DirectoryEPUBPackageTests")
struct DirectoryEPUBPackageTests {
    @Test
    func parsesNestedDefaultRenditionManifestSpineAndFragments() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeContainer(rootfiles: ["OPS/package.opf", "ALT/ignored.opf"])
        try fixture.writeOPF("""
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>
            <item id="chapter" href="Text/Chapter%201.xhtml#part%201" media-type="application/xhtml+xml" properties="scripted nav"/>
            <item id="shared" href="../shared.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="chapter"/><itemref idref="shared"/></spine>
        </package>
        """, at: "OPS/package.opf")

        let package = try DirectoryEPUBPackage(root: fixture.root)
        #expect(package.packageDocument.relativePath == "OPS/package.opf")
        #expect(package.manifest["chapter"]?.path.relativePath == "OPS/Text/Chapter 1.xhtml")
        #expect(package.manifest["chapter"]?.path.fragment == "part 1")
        #expect(package.manifest["chapter"]?.properties == ["scripted", "nav"])
        #expect(package.manifest["shared"]?.path.relativePath == "shared.xhtml")
        #expect(package.spine == [
            EPUBSpineItem(idref: "chapter", order: 1),
            EPUBSpineItem(idref: "shared", order: 2),
        ])
    }

    @Test
    func rejectsExternalMalformedAndEscapingReferences() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        for reference in [
            "https://example.invalid/ch.xhtml",
            "file:chapter.xhtml",
            "//example.invalid/ch.xhtml",
            "/absolute/ch.xhtml",
            "chapter.xhtml?query=1",
            "chapter%2.xhtml",
            "%2Fabsolute.xhtml",
            "https%3A%2F%2Fexample.invalid%2Fch.xhtml",
            "chapter\0.xhtml",
        ] {
            #expect(throws: EPUBPathError.invalidReference) {
                _ = try EPUBPath.resolve(reference: reference)
            }
        }

        #expect(throws: EPUBPathError.rootEscape) {
            _ = try EPUBPath.resolve(
                reference: "%2E%2E/%2E%2E/outside.xhtml",
                relativeTo: "OPS"
            )
        }
    }

    @Test
    func rejectsRootAndInternalSymlinksBeforeMetadataRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.writeContainer(rootfiles: ["OPS/package.opf"])
        try fixture.writeOPF(validOPF, at: "real-package.opf")
        try fixture.createSymlink(at: "OPS/package.opf", pointingTo: fixture.root.appendingPathComponent("real-package.opf"))

        #expect(throws: EPUBResourceError.unsafeResource) {
            _ = try DirectoryEPUBPackage(root: fixture.root)
        }

        let rootLink = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: rootLink) }
        #expect(throws: EPUBResourceError.unsafeResource) {
            _ = try DirectoryEPUBPackage(root: rootLink)
        }
    }

    @Test
    func rejectsMalformedContainerDuplicateManifestAndBrokenSpine() throws {
        let malformed = try Fixture()
        defer { malformed.remove() }
        try malformed.write("<container", at: "META-INF/container.xml")
        #expect(throws: DirectoryEPUBPackageError.invalidContainer) {
            _ = try DirectoryEPUBPackage(root: malformed.root)
        }

        let invalidContainerStructure = try Fixture()
        defer { invalidContainerStructure.remove() }
        try invalidContainerStructure.write("""
        <wrapper xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="package.opf"/></rootfiles>
        </wrapper>
        """, at: "META-INF/container.xml")
        #expect(throws: DirectoryEPUBPackageError.invalidContainer) {
            _ = try DirectoryEPUBPackage(root: invalidContainerStructure.root)
        }

        let invalidPackageStructure = try Fixture()
        defer { invalidPackageStructure.remove() }
        try invalidPackageStructure.writeContainer(rootfiles: ["package.opf"])
        try invalidPackageStructure.writeOPF("""
        <package xmlns="http://www.idpf.org/2007/opf">
          <manifest><item id="chapter" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
          <itemref idref="chapter"/>
        </package>
        """, at: "package.opf")
        #expect(throws: DirectoryEPUBPackageError.invalidPackageDocument) {
            _ = try DirectoryEPUBPackage(root: invalidPackageStructure.root)
        }

        let duplicate = try Fixture()
        defer { duplicate.remove() }
        try duplicate.writeContainer(rootfiles: ["package.opf"])
        try duplicate.writeOPF("""
        <package xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="same" href="a.xhtml" media-type="application/xhtml+xml"/>
            <item id="same" href="b.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="same"/></spine>
        </package>
        """, at: "package.opf")
        #expect(throws: DirectoryEPUBPackageError.duplicateManifestID) {
            _ = try DirectoryEPUBPackage(root: duplicate.root)
        }

        let broken = try Fixture()
        defer { broken.remove() }
        try broken.writeContainer(rootfiles: ["package.opf"])
        try broken.writeOPF("""
        <package xmlns="http://www.idpf.org/2007/opf">
          <manifest><item id="chapter" href="a.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="missing"/></spine>
        </package>
        """, at: "package.opf")
        #expect(throws: DirectoryEPUBPackageError.invalidSpineReference) {
            _ = try DirectoryEPUBPackage(root: broken.root)
        }
    }

    @Test
    func missingMetadataFilesFailClosedAndExternalDTDIsNeverResolved() throws {
        let missing = try Fixture()
        defer { missing.remove() }
        #expect(throws: ContentError.unavailable(.missing)) {
            _ = try DirectoryEPUBPackage(root: missing.root)
        }

        let externalDTD = try Fixture()
        defer { externalDTD.remove() }
        try externalDTD.write("""
        <?xml version="1.0"?>
        <!DOCTYPE container SYSTEM "file:///definitely/not-present/applebookscli.dtd">
        <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
          <rootfiles><rootfile full-path="package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """, at: "META-INF/container.xml")
        try externalDTD.writeOPF(validOPF, at: "package.opf")
        #expect(try DirectoryEPUBPackage(root: externalDTD.root).packageDocument.relativePath == "package.opf")
    }

    private var validOPF: String {
        """
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
    }

    private final class Fixture {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func writeContainer(rootfiles: [String]) throws {
            let rows = rootfiles.map {
                "<rootfile full-path=\"\($0)\" media-type=\"application/oebps-package+xml\"/>"
            }.joined()
            try write("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles>\(rows)</rootfiles>
            </container>
            """, at: "META-INF/container.xml")
        }

        func writeOPF(_ value: String, at relativePath: String) throws {
            try write(value, at: relativePath)
        }

        func write(_ value: String, at relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }

        func createSymlink(at relativePath: String, pointingTo target: URL) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        }
    }
}

import Foundation
import Testing
@testable import AppleBooksCore

@Suite("EPUBCoverTests")
struct EPUBCoverTests {
    @Test
    func epub3ManifestPropertyWinsAndDetectedMediaTypeOverridesDeclaration() throws {
        let fixture = try makeEPUB(
            metadata: "<meta name=\"cover\" content=\"legacy\"/>",
            manifest: """
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="property" href="images/property.png" media-type="image/jpeg" properties="cover-image"/>
            <item id="legacy" href="images/legacy.jpg" media-type="image/jpeg"/>
            """
        )
        defer { fixture.cleanup() }
        let png = Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A,0x01])
        let jpeg = Data([0xFF,0xD8,0xFF,0x01])
        try write(png, relative: "OPS/images/property.png", root: fixture.root)
        try write(jpeg, relative: "OPS/images/legacy.jpg", root: fixture.root)
        try write(Data("GIF89a".utf8), relative: "cover.gif", root: fixture.root)

        let cover = try #require(try BookContent(root: fixture.root).cover())
        #expect(cover.data == png)
        #expect(cover.source == .manifestProperty)
        #expect(cover.declaredMediaType == "image/jpeg")
        #expect(cover.detectedMediaType == "image/png")
        #expect(cover.mediaType == "image/png")
    }

    @Test
    func epub2MetadataIDUsesActualOPFDirectory() throws {
        let fixture = try makeEPUB(
            metadata: "<meta name=\"cover\" content=\"legacy\"/>",
            manifest: """
            <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="legacy" href="images/legacy.jpg" media-type="image/jpeg"/>
            """
        )
        defer { fixture.cleanup() }
        let nested = Data([0xFF,0xD8,0xFF,0x22])
        let misleadingRoot = Data([0xFF,0xD8,0xFF,0x33])
        try write(nested, relative: "OPS/images/legacy.jpg", root: fixture.root)
        try write(misleadingRoot, relative: "images/legacy.jpg", root: fixture.root)

        let cover = try #require(try BookContent(root: fixture.root).cover())
        #expect(cover.data == nested)
        #expect(cover.source == .metadataID)
        #expect(cover.mediaType == "image/jpeg")
    }

    @Test
    func commonNameFallbackIsFiniteDeterministicAndRejectsSymlinkCandidate() throws {
        let fixture = try makeEPUB(
            metadata: "",
            manifest: "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>"
        )
        defer { fixture.cleanup() }
        let outside = fixture.parent.appendingPathComponent("outside.jpg")
        try Data([0xFF,0xD8,0xFF,0x44]).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("cover.jpg"),
            withDestinationURL: outside
        )
        let valid = Data([0xFF,0xD8,0xFF,0x55])
        try write(valid, relative: "OEBPS/cover.jpg", root: fixture.root)
        try write(Data("GIF89a".utf8), relative: "OPS/cover.gif", root: fixture.root)

        let cover = try #require(try BookContent(root: fixture.root).cover())
        #expect(cover.data == valid)
        #expect(cover.source == .commonNameFallback)
        #expect(cover.declaredMediaType == nil)
        #expect(cover.detectedMediaType == "image/jpeg")
    }

    @Test
    func noDeclaredOrExactFallbackCoverReturnsNil() throws {
        let fixture = try makeEPUB(
            metadata: "",
            manifest: "<item id=\"chapter\" href=\"chapter.xhtml\" media-type=\"application/xhtml+xml\"/>"
        )
        defer { fixture.cleanup() }
        try write(Data([0x89,0x50,0x4E,0x47]), relative: "OPS/images/not-cover.png", root: fixture.root)

        #expect(try BookContent(root: fixture.root).cover() == nil)
    }

    private func makeEPUB(metadata: String, manifest: String) throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = parent.appendingPathComponent("book.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <metadata>\(metadata)</metadata>
          <manifest>\(manifest)</manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body>chapter</body></html>".utf8).write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
        return Fixture(parent: parent, root: root)
    }

    private func write(_ data: Data, relative: String, root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private struct Fixture {
        let parent: URL
        let root: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}

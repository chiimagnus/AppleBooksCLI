import Foundation
import Testing
@testable import AppleBooksCore

@Suite("EPUBEncryptionTests")
struct EPUBEncryptionTests {
    @Test
    func missingEncryptionIsNoneEvenWhenOtherRightsMetadataExists() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("<rights/>", at: "META-INF/sinf.xml")

        #expect(try EPUBEncryption.inspect(package: fixture.package()) == .none)
    }

    @Test
    func classifiesOnlyStandardFontObfuscationAsReadable() throws {
        let fixture = try Fixture(manifest: """
        <item id="ttf" href="Fonts/A.ttf" media-type="font/ttf"/>
        <item id="woff" href="Fonts/B.woff2" media-type="font/woff2"/>
        """)
        defer { fixture.remove() }
        try fixture.writeEncryption(entries: [
            (algorithm: Fixture.fontAlgorithm, uri: "EPUB/Fonts/A.ttf"),
            (algorithm: Fixture.fontAlgorithm, uri: "EPUB/Fonts/B.woff2"),
        ])

        #expect(try EPUBEncryption.inspect(package: fixture.package()) == .fontObfuscationOnly)
    }

    @Test
    func unknownAlgorithmsAndNonFontTargetsAreUnsupported() throws {
        let unknown = try Fixture(manifest: """
        <item id="font" href="Fonts/A.ttf" media-type="font/ttf"/>
        """)
        defer { unknown.remove() }
        try unknown.writeEncryption(entries: [(algorithm: "urn:synthetic:unknown", uri: "EPUB/Fonts/A.ttf")])
        #expect(try EPUBEncryption.inspect(package: unknown.package()) == .contentEncryptionUnsupported)

        let xhtml = try Fixture(manifest: """
        <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
        """)
        defer { xhtml.remove() }
        try xhtml.writeEncryption(entries: [(algorithm: Fixture.fontAlgorithm, uri: "EPUB/Text/chapter.xhtml")])
        #expect(try EPUBEncryption.inspect(package: xhtml.package()) == .contentEncryptionUnsupported)

        let absent = try Fixture(manifest: """
        <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
        """)
        defer { absent.remove() }
        try absent.writeEncryption(entries: [(algorithm: Fixture.fontAlgorithm, uri: "EPUB/Fonts/not-in-manifest.ttf")])
        #expect(try EPUBEncryption.inspect(package: absent.package()) == .contentEncryptionUnsupported)
    }

    @Test
    func malformedEntriesAndEscapedTargetsFailClosed() throws {
        let malformedXML = try Fixture()
        defer { malformedXML.remove() }
        try malformedXML.write("<encryption", at: "META-INF/encryption.xml")
        #expect(try EPUBEncryption.inspect(package: malformedXML.package()) == .malformedEncryptionMetadata)

        let missingAlgorithm = try Fixture()
        defer { missingAlgorithm.remove() }
        try missingAlgorithm.write("""
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData><enc:CipherData><enc:CipherReference URI="EPUB/Fonts/A.ttf"/></enc:CipherData></enc:EncryptedData>
        </encryption>
        """, at: "META-INF/encryption.xml")
        #expect(try EPUBEncryption.inspect(package: missingAlgorithm.package()) == .malformedEncryptionMetadata)

        let escaped = try Fixture()
        defer { escaped.remove() }
        try escaped.writeEncryption(entries: [(algorithm: Fixture.fontAlgorithm, uri: "../../outside.ttf")])
        #expect(try EPUBEncryption.inspect(package: escaped.package()) == .malformedEncryptionMetadata)
    }

    @Test
    func externalDTDIsNeverResolved() throws {
        let fixture = try Fixture(manifest: """
        <item id="font" href="Fonts/A.ttf" media-type="font/ttf"/>
        """)
        defer { fixture.remove() }
        try fixture.write("""
        <?xml version="1.0"?>
        <!DOCTYPE encryption SYSTEM "file:///definitely/not-present/applebookscli-encryption.dtd">
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="\(Fixture.fontAlgorithm)"/>
            <enc:CipherData><enc:CipherReference URI="EPUB/Fonts/A.ttf"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """, at: "META-INF/encryption.xml")

        #expect(try EPUBEncryption.inspect(package: fixture.package()) == .fontObfuscationOnly)
    }

    private final class Fixture {
        static let fontAlgorithm = "http://www.idpf.org/2008/embedding"

        let root: URL
        private let manifest: String

        init(manifest: String = "<item id=\"font\" href=\"Fonts/A.ttf\" media-type=\"font/ttf\"/>") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            self.manifest = manifest
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try write("""
            <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
              <rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, at: "META-INF/container.xml")
            try write("""
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
              <manifest>\(manifest)</manifest>
              <spine></spine>
            </package>
            """, at: "EPUB/package.opf")
        }

        func package() throws -> DirectoryEPUBPackage {
            try DirectoryEPUBPackage(root: root)
        }

        func writeEncryption(entries: [(algorithm: String, uri: String)]) throws {
            let body = entries.map { entry in
                """
                <enc:EncryptedData>
                  <enc:EncryptionMethod Algorithm="\(entry.algorithm)"/>
                  <enc:CipherData><enc:CipherReference URI="\(entry.uri)"/></enc:CipherData>
                </enc:EncryptedData>
                """
            }.joined()
            try write("""
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              \(body)
            </encryption>
            """, at: "META-INF/encryption.xml")
        }

        func write(_ value: String, at relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

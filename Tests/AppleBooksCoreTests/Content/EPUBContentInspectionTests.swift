import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import AppleBooksCore

@Suite("EPUBContentInspectionTests")
struct EPUBContentInspectionTests {
    @Test
    func statusInspectsPackageAndEncryptionWithoutReadingChapterBody() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let epub = fixture.root.appendingPathComponent("current.epub", isDirectory: true)
        try fixture.makeDirectoryEPUB(at: epub, includeChapterBody: false)
        let books = try fixture.makeBooks(path: epub.path)

        let status = try #require(try books.contentStatus(forBookLocalPK: 1))
        #expect(status.currentAvailability == .available)
        #expect(status.supplementalAvailability == nil)
        #expect(status.selectedSource == .current)
        #expect(status.materialization == .available)
        #expect(status.encryption == EPUBEncryption.none)
        #expect(status.unavailableReason == nil)
        #expect(status.isReady)
    }

    @Test
    func missingBookPathPreservesItsPreciseUnavailableReason() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let books = try fixture.makeBooks(path: nil)

        let status = try #require(try books.contentStatus(forBookLocalPK: 1))
        #expect(status.currentAvailability == nil)
        #expect(status.supplementalAvailability == nil)
        #expect(status.selectedSource == nil)
        #expect(status.materialization == .missing)
        #expect(status.encryption == nil)
        #expect(status.unavailableReason == .bookPathUnavailable)
        #expect(status.isReady == false)
    }

    @Test
    func statusReportsUnsupportedContentEncryptionWithoutPretendingContentIsReady() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let epub = fixture.root.appendingPathComponent("encrypted.epub", isDirectory: true)
        try fixture.makeDirectoryEPUB(at: epub, includeChapterBody: false)
        try Data("""
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="urn:synthetic:unsupported"/>
            <enc:CipherData><enc:CipherReference URI="OPS/chapter.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """.utf8).write(to: epub.appendingPathComponent("META-INF/encryption.xml"))
        let books = try fixture.makeBooks(path: epub.path)

        let status = try #require(try books.contentStatus(forBookLocalPK: 1))
        #expect(status.selectedSource == .current)
        #expect(status.materialization == .available)
        #expect(status.encryption == .contentEncryptionUnsupported)
        #expect(status.unavailableReason == .contentEncryptionUnsupported)
        #expect(status.isReady == false)
    }

    @Test
    func supplementalPackedFallbackOwnsStatusMetadataAndLocateProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let supplementalRoot = fixture.root.appendingPathComponent("supplemental", isDirectory: true)
        try FileManager.default.createDirectory(at: supplementalRoot, withIntermediateDirectories: true)
        let packed = supplementalRoot.appendingPathComponent("book.epub")
        try fixture.makePackedEPUB(at: packed)
        let missingCurrent = fixture.root.appendingPathComponent("missing/book.epub", isDirectory: true)
        let books = try fixture.makeBooks(path: missingCurrent.path, supplementalRoot: supplementalRoot)

        let status = try #require(try books.contentStatus(forBookLocalPK: 1))
        #expect(status.currentAvailability == .missing)
        #expect(status.supplementalAvailability == .available)
        #expect(status.selectedSource == .supplemental)
        #expect(status.encryption == EPUBEncryption.none)
        #expect(status.isReady)

        let metadata = try #require(try books.contentMetadata(forBookLocalPK: 1))
        #expect(metadata.source == .supplemental)
        #expect(metadata.book.title == "DB Title")
        #expect(metadata.book.author == "DB Author")
        #expect(metadata.metadata.title == "EPUB Title")
        #expect(metadata.metadata.creator == "EPUB Author")
        #expect(metadata.enrichment.publisher == "EPUB Publisher")

        let located = try #require(try books.locate(
            rawCFI: "epubcfi(/6/2[chapter]!/4/2,:4,:8)",
            forBookLocalPK: 1
        ))
        #expect(located.source == .supplemental)
        #expect(located.location.rawCFI == "epubcfi(/6/2[chapter]!/4/2,:4,:8)")
        #expect(located.location.chapterID == "chapter")
        #expect(located.location.characterRange == .init(start: 4, end: 8))
        #expect(located.chapter?.id == "chapter")
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

        func makeBooks(path: String?, supplementalRoot: URL? = nil) throws -> AppleBooks {
            let library = root.appendingPathComponent(UUID().uuidString + "-library.sqlite")
            let annotations = root.appendingPathComponent(UUID().uuidString + "-annotations.sqlite")
            try createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZAUTHOR TEXT,
              ZPATH TEXT,
              ZLANGUAGE TEXT,
              ZRELEASEDATE REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset','DB Title','DB Author',\(path.map { "'\(sql($0))'" } ?? "NULL"),'db-lang',123);
            """)
            try createDatabase(annotations, sql: "CREATE TABLE placeholder(value INTEGER);")
            let config = root.appendingPathComponent(UUID().uuidString + "-config.json")
            let rootJSON = supplementalRoot.map { ",\"epub_root\":\"\(json($0.path))\"" } ?? ""
            try Data("{\"historical_assets\":{}\(rootJSON)}".utf8).write(to: config)
            return try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func makeDirectoryEPUB(at epub: URL, includeChapterBody: Bool) throws {
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: epub.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try containerData().write(to: epub.appendingPathComponent("META-INF/container.xml"))
            try packageData().write(to: epub.appendingPathComponent("OPS/package.opf"))
            if includeChapterBody {
                try Data("<html><body>chapter</body></html>".utf8).write(to: epub.appendingPathComponent("OPS/chapter.xhtml"))
            }
        }

        func makePackedEPUB(at url: URL) throws {
            let resources: [String: Data] = [
                "META-INF/container.xml": containerData(),
                "OPS/package.opf": packageData(),
                "OPS/chapter.xhtml": Data("<html><body>chapter</body></html>".utf8),
            ]
            let archive = try Archive(url: url, accessMode: .create)
            for (path, data) in resources.sorted(by: { $0.key < $1.key }) {
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return start < end ? data.subdata(in: start..<end) : Data()
                }
            }
        }

        private func containerData() -> Data {
            Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
        }

        private func packageData() -> Data {
            Data("""
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata>
                <dc:title>EPUB Title</dc:title>
                <dc:creator>EPUB Author</dc:creator>
                <dc:publisher>EPUB Publisher</dc:publisher>
              </metadata>
              <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8)
        }

        private func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else { throw FixtureError.sqlite }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        }

        private func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }

        private func json(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
    }

    private enum FixtureError: Error {
        case sqlite
    }
}

import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("EPUBMetadataTests")
struct EPUBMetadataTests {
    @Test
    func parsesNamespaceAwareOPFMetadataAndCanonicalISBN() throws {
        let root = try makeEPUB(metadata: """
        <dc:title>EPUB Title</dc:title>
        <dc:creator>EPUB Author</dc:creator>
        <dc:identifier>internal-id</dc:identifier>
        <dc:identifier opf:scheme="ISBN">978-0-306-40615-7</dc:identifier>
        <dc:language>en</dc:language>
        <dc:publisher>Publisher</dc:publisher>
        <dc:date>2025-01-02</dc:date>
        <dc:rights>Rights</dc:rights>
        <dc:subject>One</dc:subject>
        <dc:subject>Two</dc:subject>
        <meta name="cover" content="cover-item"/>
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let metadata = try BookContent(root: root).metadata()
        #expect(metadata.title == "EPUB Title")
        #expect(metadata.creator == "EPUB Author")
        #expect(metadata.identifiers == ["internal-id", "978-0-306-40615-7"])
        #expect(metadata.isbn == "9780306406157")
        #expect(metadata.language == "en")
        #expect(metadata.publisher == "Publisher")
        #expect(metadata.publicationDate == "2025-01-02")
        #expect(metadata.rights == "Rights")
        #expect(metadata.subjects == ["One", "Two"])
        #expect(metadata.coverItemID == "cover-item")
    }

    @Test
    func validISBNValueNeedsNoSchemeButOtherIdentifiersNeverMasqueradeAsISBN() throws {
        let valid = try makeEPUB(metadata: """
        <dc:identifier>0-306-40615-2</dc:identifier>
        <dc:identifier>not-an-isbn</dc:identifier>
        """)
        defer { try? FileManager.default.removeItem(at: valid.deletingLastPathComponent()) }
        #expect(try BookContent(root: valid).metadata().isbn == "0306406152")

        let invalid = try makeEPUB(metadata: "<dc:identifier>not-an-isbn</dc:identifier>")
        defer { try? FileManager.default.removeItem(at: invalid.deletingLastPathComponent()) }
        #expect(try BookContent(root: invalid).metadata().isbn == nil)
    }

    @Test
    func iTunesPlistOnlyFillsMissingRawSourceFieldsAndMalformedPlistIsIgnored() throws {
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "artistName": "iTunes Author",
                "itemName": "iTunes Title",
                "publisher": "iTunes Publisher",
            ],
            format: .xml,
            options: 0
        )
        let root = try makeEPUB(metadata: "<dc:language>fr</dc:language>", iTunesPlist: plist)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let metadata = try BookContent(root: root).metadata()
        #expect(metadata.title == "iTunes Title")
        #expect(metadata.creator == "iTunes Author")
        #expect(metadata.publisher == "iTunes Publisher")
        #expect(metadata.language == "fr")

        let malformed = try makeEPUB(metadata: "<dc:publisher>OPF Publisher</dc:publisher>", iTunesPlist: Data("not a plist".utf8))
        defer { try? FileManager.default.removeItem(at: malformed.deletingLastPathComponent()) }
        let malformedMetadata = try BookContent(root: malformed).metadata()
        #expect(malformedMetadata.publisher == "OPF Publisher")
        #expect(malformedMetadata.title == nil)
    }

    @Test
    func emptyDCElementCannotPolluteFollowingMetadata() throws {
        let root = try makeEPUB(metadata: """
        <dc:title>   </dc:title>
        <meta property="ignored">noise</meta>
        <dc:publisher>Clean Publisher</dc:publisher>
        """)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let metadata = try BookContent(root: root).metadata()
        #expect(metadata.title == nil)
        #expect(metadata.publisher == "Clean Publisher")
    }

    @Test
    func enrichmentNeverOverridesCanonicalBookIdentityTitleAuthorLanguageOrReleaseDate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = try database(at: root.appendingPathComponent("library.sqlite"), sql: """
        CREATE TABLE ZBKLIBRARYASSET(
          Z_PK INTEGER PRIMARY KEY,
          ZASSETID TEXT,
          ZTITLE TEXT,
          ZAUTHOR TEXT,
          ZLANGUAGE TEXT,
          ZRELEASEDATE REAL
        );
        INSERT INTO ZBKLIBRARYASSET VALUES (1,'db-asset','DB Title','DB Author','db-lang',123);
        """)
        let book = try #require(try BookQueries(connection: SQLiteConnection.readOnly(path: databaseURL.path)).list().first)
        let epub = try makeEPUB(in: root, name: "metadata", metadata: """
        <dc:title>EPUB Title</dc:title>
        <dc:creator>EPUB Author</dc:creator>
        <dc:identifier opf:scheme="ISBN">9780306406157</dc:identifier>
        <dc:language>epub-lang</dc:language>
        <dc:publisher>EPUB Publisher</dc:publisher>
        <dc:date>2026</dc:date>
        <dc:rights>EPUB Rights</dc:rights>
        <dc:subject>Subject</dc:subject>
        """)
        let raw = try BookContent(root: epub).metadata()
        let enrichment = raw.supplementing(book)

        #expect(book.assetID == "db-asset")
        #expect(book.title == "DB Title")
        #expect(book.author == "DB Author")
        #expect(raw.title == "EPUB Title")
        #expect(raw.creator == "EPUB Author")
        #expect(enrichment.isbn == "9780306406157")
        #expect(enrichment.language == nil)
        #expect(enrichment.publisher == "EPUB Publisher")
        #expect(enrichment.publicationDate == nil)
        #expect(enrichment.rights == "EPUB Rights")
        #expect(enrichment.subjects == ["Subject"])
    }

    private func makeEPUB(metadata: String, iTunesPlist: Data? = nil) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return try makeEPUB(in: parent, name: "book", metadata: metadata, iTunesPlist: iTunesPlist)
    }

    private func makeEPUB(in parent: URL, name: String, metadata: String, iTunesPlist: Data? = nil) throws -> URL {
        let root = parent.appendingPathComponent(name).appendingPathExtension("epub")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
        try Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8)
            .write(to: root.appendingPathComponent("META-INF/container.xml"))
        try Data("""
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
          <metadata>\(metadata)</metadata>
          <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """.utf8).write(to: root.appendingPathComponent("OPS/package.opf"))
        try Data("<html><body>chapter</body></html>".utf8).write(to: root.appendingPathComponent("OPS/chapter.xhtml"))
        if let iTunesPlist {
            try iTunesPlist.write(to: root.appendingPathComponent("iTunesMetadata.plist"))
        }
        return root
    }

    private func database(at url: URL, sql: String) throws -> URL {
        var handle: OpaquePointer?
        let open = sqlite3_open(url.path, &handle)
        guard open == SQLITE_OK, let handle else {
            throw SQLiteError.current(operation: .open, code: open, handle: handle)
        }
        defer { sqlite3_close(handle) }
        let result = sqlite3_exec(handle, sql, nil, nil, nil)
        guard result == SQLITE_OK else {
            throw SQLiteError.current(operation: .step, code: result, handle: handle)
        }
        return url
    }
}

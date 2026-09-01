import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import AppleBooksCore

@Suite("ExtendedReadParityTests")
struct ExtendedReadParityTests {
    @Test
    func extendedReadOwnersComposeAcrossPackedAndDirectorySources() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let packedBook = try #require(try fixture.books.book(localPK: 1))
        #expect(packedBook.author == "Ada\u{E123} Lovelace")
        #expect(packedBook.normalizedAuthor == "Ada Lovelace")
        #expect(packedBook.genresRaw == Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(packedBook.epubID == "epub-id-packed")
        #expect(packedBook.comments == "")
        #expect(packedBook.year == 2026)
        #expect(packedBook.pageCount == 321)
        #expect(packedBook.rating == 4.5)

        let directoryBook = try #require(try fixture.books.book(localPK: 2))
        #expect(directoryBook.author == " unknown ")
        #expect(directoryBook.normalizedAuthor == nil)

        let overviews = try fixture.books.annotatedBooks()
        #expect(overviews.map(\.book.localPK) == [1, 2, 3])
        #expect(overviews.map(\.userAnnotationCount) == [2, 1, 1])
        #expect(try fixture.books.bookOverview(assetID: "asset-packed")?.userAnnotationCount == 2)

        let stats = try fixture.books.libraryStats()
        #expect(stats.totalBooks == 4)
        #expect(stats.finishedBooks == 1)
        #expect(stats.inProgressBooks == 1)
        #expect(stats.unstartedBooks == 2)
        #expect(stats.totalUserAnnotations == 5)
        #expect(stats.orphanUserAnnotations == 1)
        #expect(stats.topAnnotatedBooks.map(\.book.localPK) == [1, 2, 3])
        #expect(stats.topAnnotatedBooks.map(\.userAnnotationCount) == [2, 1, 1])

        #expect(try fixture.books.recentlyCreatedAnnotations().map { $0.annotation.localPK } == [14, 13, 12, 11, 10])
        #expect(try fixture.books.annotationsInReadingOrder(bookLocalPK: 1).map { $0.annotation.localPK } == [10, 11])

        let packed = try fixture.books.bookContent(forBookLocalPK: 1)
        let directory = try fixture.books.bookContent(forBookLocalPK: 2)
        #expect(try packed.listChapters() == directory.listChapters())
        #expect(try packed.getChapter("c1") == directory.getChapter("c1"))
        #expect(try packed.getChapter("c2") == directory.getChapter("c2"))
        #expect(try packed.metadata() == directory.metadata())
        #expect(try packed.cover() == directory.cover())

        let page = try packed.chapterPage(id: "c1", offset: 6, maxCharacters: 1)
        #expect(page.content == "👨‍👩‍👧‍👦")
        #expect(page.endOffset == 7)
        #expect(page.nextOffset == 7)
        #expect(try directory.chapterPage(id: "c1", offset: 6, maxCharacters: 1) == page)

        let metadata = try packed.metadata()
        #expect(metadata.title == "OPF Title")
        #expect(metadata.creator == "OPF Creator")
        #expect(metadata.publisher == "Plist Publisher")
        #expect(metadata.isbn == "9780306406157")
        #expect(metadata.language == "en")
        #expect(metadata.publicationDate == "2026-01-02")
        #expect(metadata.rights == "Fixture Rights")
        #expect(metadata.subjects == ["Fiction", "Exact XML"])

        let enrichment = metadata.supplementing(packedBook)
        #expect(enrichment.language == "en")
        #expect(enrichment.publicationDate == "2026-01-02")
        #expect(enrichment.publisher == "Plist Publisher")

        let cover = try #require(try packed.cover())
        #expect(cover.source == .manifestProperty)
        #expect(cover.mediaType == "image/png")
        #expect(cover.data == Fixture.coverData)

        let bookmark = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 1))
        #expect(bookmark == ReadingPosition(
            chapterID: "c2",
            title: "Section 2",
            order: 2,
            totalChapters: 2,
            source: .bookmarkToc
        ))
        #expect(try fixture.books.currentReadingPosition(forBookLocalPK: 4) == ReadingPosition(
            chapterID: "outside",
            title: nil,
            order: nil,
            totalChapters: nil,
            source: .bookmarkHint
        ))

        let context = try fixture.books.annotationContext(localPK: 10, charsBefore: 8, charsAfter: 8)
        #expect(context.matched == "Visible chapter")
        #expect(context.markedPresentation.matched)
        #expect(context.markedPresentation.text.contains("«Visible chapter»"))
    }

    @Test
    func deliberateDifferencesStayExplicitAndHistoricalContentNeverGuesses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let packedBook = try #require(try fixture.books.book(localPK: 1))
        #expect(packedBook.genresRaw == Data([0x00, 0x01, 0x02, 0xFF]))
        #expect(packedBook.author == "Ada\u{E123} Lovelace")
        #expect(packedBook.normalizedAuthor == "Ada Lovelace")

        let inferred = try #require(try fixture.books.currentReadingPosition(forBookLocalPK: 3))
        #expect(try fixture.books.currentReadingLocation(forBookLocalPK: 3)?.location == nil)
        #expect(inferred == ReadingPosition(
            chapterID: "c1",
            title: "Section 1",
            order: nil,
            totalChapters: nil,
            source: .recentAnnotationInference
        ))

        let historical = try #require(try fixture.books.annotation(localPK: 14))
        #expect(historical.source == .historicalInferred(HistoricalBookMetadata(title: "Historical", author: "Mapped Author")))
        #expect(throws: AnnotationContextError.currentBookUnavailable) {
            _ = try fixture.books.annotationContext(localPK: 14)
        }

        #expect(fixture.books.configuration.epubRoot == fixture.supplementalRoot.standardizedFileURL.resolvingSymlinksInPath())
        #expect(fixture.books.configuration.historicalAssets.metadata(for: "asset-historical") == HistoricalBookMetadata(
            title: "Historical",
            author: "Mapped Author"
        ))

        let packed = try fixture.books.bookContent(forBookLocalPK: 1)
        let metadata = try packed.metadata()
        #expect(metadata.title == "OPF Title")
        #expect(metadata.creator == "OPF Creator")
        #expect(metadata.publisher == "Plist Publisher")

        let page = try packed.chapterPage(id: "c1", offset: 6, maxCharacters: 1)
        #expect(page.content == "👨‍👩‍👧‍👦")
    }

    private final class Fixture {
        static let coverData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])

        let root: URL
        let supplementalRoot: URL
        let books: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            supplementalRoot = root.appendingPathComponent("supplemental", isDirectory: true)
            let directoryEPUB = root.appendingPathComponent("directory-source.epub", isDirectory: true)
            let missingPackedPath = root.appendingPathComponent("current", isDirectory: true)
                .appendingPathComponent("packed-source.epub")
            try FileManager.default.createDirectory(at: supplementalRoot, withIntermediateDirectories: true)

            let resources = try Self.logicalResources()
            try Self.writeResources(resources, to: directoryEPUB)
            try Self.makeZip(
                at: supplementalRoot.appendingPathComponent("packed-source.epub"),
                resources: resources
            )
            try Self.makeZip(
                at: supplementalRoot.appendingPathComponent("asset-historical.epub"),
                resources: resources
            )

            let library = root.appendingPathComponent("library.sqlite")
            try Self.createDatabase(library, sql: """
            CREATE TABLE ZBKLIBRARYASSET(
              Z_PK INTEGER PRIMARY KEY,
              ZASSETID TEXT,
              ZTITLE TEXT,
              ZAUTHOR TEXT,
              ZEPUBID TEXT,
              ZGENRE TEXT,
              ZGENRES BLOB,
              ZCOMMENTS TEXT,
              ZLANGUAGE TEXT,
              ZYEAR INTEGER,
              ZCONTENTTYPE INTEGER,
              ZPAGECOUNT INTEGER,
              ZPATH TEXT,
              ZCOVERURL TEXT,
              ZISFINISHED INTEGER,
              ZREADINGPROGRESS REAL,
              ZLASTOPENDATE REAL,
              ZMODIFICATIONDATE REAL,
              ZRELEASEDATE REAL,
              ZRATING REAL
            );
            INSERT INTO ZBKLIBRARYASSET VALUES
              (1,'asset-packed','A Packed','Ada\u{E123} Lovelace','epub-id-packed','Fiction',X'000102FF','',NULL,2026,1,321,'\(Self.sql(missingPackedPath.path))','db-cover',0,0.5,100,0,NULL,4.5),
              (2,'asset-directory','B Directory',' unknown ','epub-id-directory','Reference',NULL,'raw','fr',2025,1,100,'\(Self.sql(directoryEPUB.path))',NULL,1,1.0,90,1,2,3.0),
              (3,'asset-third','C Third','Third Author',NULL,NULL,NULL,NULL,NULL,NULL,1,NULL,'\(Self.sql(directoryEPUB.path))',NULL,0,0,80,NULL,NULL,NULL),
              (4,'asset-hint','D Hint','Hint Author',NULL,NULL,NULL,NULL,NULL,NULL,1,NULL,'\(Self.sql(directoryEPUB.path))',NULL,0,0,70,NULL,NULL,NULL);
            """)

            let annotations = root.appendingPathComponent("annotations.sqlite")
            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
              Z_PK INTEGER PRIMARY KEY,
              ZANNOTATIONUUID TEXT,
              ZANNOTATIONASSETID TEXT,
              ZANNOTATIONDELETED INTEGER,
              ZANNOTATIONTYPE INTEGER,
              ZANNOTATIONCREATIONDATE REAL,
              ZANNOTATIONMODIFICATIONDATE REAL,
              ZANNOTATIONSELECTEDTEXT TEXT,
              ZANNOTATIONREPRESENTATIVETEXT TEXT,
              ZANNOTATIONNOTE TEXT,
              ZANNOTATIONLOCATION TEXT
            );
            INSERT INTO ZAEANNOTATION VALUES
              (10,'uuid-packed-c1','asset-packed',0,1,10,10,'Visible chapter','Visible chapter','note','epubcfi(/6/2[c1]!/4/2,:0,:0)'),
              (11,'uuid-packed-c2','asset-packed',0,1,20,20,'Second chapter','Second chapter','note','epubcfi(/6/2[c2]!/4/2,:0,:0)'),
              (12,'uuid-third-c1','asset-third',0,1,30,30,'Visible chapter','Visible chapter','note','epubcfi(/6/2[c1]!/4/2,:0,:0)'),
              (13,'uuid-directory-c1','asset-directory',0,1,40,40,'Visible chapter','Visible chapter','note','epubcfi(/6/2[c1]!/4/2,:0,:0)'),
              (14,'uuid-historical','asset-historical',0,1,50,50,'Visible chapter','Visible chapter','note','epubcfi(/6/2[c1]!/4/2,:0,:0)'),
              (20,'bookmark-packed','asset-packed',0,3,60,200,NULL,NULL,NULL,'epubcfi(/6/2[c2]!/4/2,:0,:0)'),
              (21,'bookmark-third','asset-third',0,3,70,300,NULL,NULL,NULL,NULL),
              (22,'bookmark-hint','asset-hint',0,3,80,400,NULL,NULL,NULL,'epubcfi(/6/2[outside]!/4/2,:0,:0)');
            """)

            let config = root.appendingPathComponent("config.json")
            let configData = try JSONSerialization.data(withJSONObject: [
                "historical_assets": [
                    "asset-historical": [
                        "title": "Historical",
                        "author": "Mapped Author",
                    ],
                ],
                "epub_root": supplementalRoot.path,
            ])
            try configData.write(to: config)
            books = try AppleBooks(libraryDB: library, annotationsDB: annotations, configurationFile: config)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func logicalResources() throws -> [String: Data] {
            let plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "itemName": "Plist Title",
                    "artistName": "Plist Creator",
                    "publisher": "Plist Publisher",
                ],
                format: .xml,
                options: 0
            )
            return [
                "META-INF/container.xml": Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8),
                "OPS/package.opf": Data("""
                <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <metadata>
                    <dc:title>OPF Title</dc:title>
                    <dc:creator>OPF Creator</dc:creator>
                    <dc:identifier>urn:isbn:9780306406157</dc:identifier>
                    <dc:language>en</dc:language>
                    <dc:date>2026-01-02</dc:date>
                    <dc:rights>Fixture Rights</dc:rights>
                    <dc:subject>Fiction</dc:subject>
                    <dc:subject>Exact XML</dc:subject>
                  </metadata>
                  <manifest>
                    <item id="c1" href="chapter-1.xhtml" media-type="application/xhtml+xml"/>
                    <item id="c2" href="chapter-2.xhtml" media-type="application/xhtml+xml"/>
                    <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
                  </manifest>
                  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
                </package>
                """.utf8),
                "OPS/chapter-1.xhtml": Data("<html><body><p>Start 👨‍👩‍👧‍👦 Visible chapter End</p></body></html>".utf8),
                "OPS/chapter-2.xhtml": Data("<html><body><p>Second chapter body</p></body></html>".utf8),
                "OPS/cover.png": coverData,
                "iTunesMetadata.plist": plist,
            ]
        }

        private static func writeResources(_ resources: [String: Data], to root: URL) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (path, data) in resources {
                let url = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
        }

        private static func makeZip(at url: URL, resources: [String: Data]) throws {
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

        private static func createDatabase(_ url: URL, sql: String) throws {
            var handle: OpaquePointer?
            let open = sqlite3_open(url.path, &handle)
            guard open == SQLITE_OK, let handle else {
                throw SQLiteError.current(operation: .open, code: open, handle: handle)
            }
            defer { sqlite3_close_v2(handle) }
            let result = sqlite3_exec(handle, sql, nil, nil, nil)
            guard result == SQLITE_OK else {
                throw SQLiteError.current(operation: .step, code: result, handle: handle)
            }
        }

        private static func sql(_ value: String) -> String {
            value.replacingOccurrences(of: "'", with: "''")
        }
    }
}

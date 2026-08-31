import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import AppleBooksCore

@Suite("SupplementalEPUBTests")
struct SupplementalEPUBTests {
    @Test
    func directoryAndZipSharePackageNavigationTextMetadataAndCoverParsers() throws {
        let fixture = try LogicalEPUBFixture()
        defer { fixture.remove() }

        let directory = try BookContent(root: fixture.directoryURL)
        let packed = try BookContent(reader: ZIPEPUBResourceReader(fileURL: fixture.zipURL))

        #expect(try directory.listChapters() == packed.listChapters())
        #expect(try directory.getChapter("chapter") == packed.getChapter("chapter"))
        #expect(try directory.metadata() == packed.metadata())
        #expect(try directory.cover() == packed.cover())
    }

    @Test
    func zipEntryPercentEscapesRemainLiteralArchiveNames() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent("literal.epub")
        try Self.makeZip(at: zip, entries: [
            .file("literal%2Fname.txt", Data("slash-literal".utf8), .none),
            .file("literal%2e%2e.txt", Data("dot-literal".utf8), .none),
        ])

        let reader = try ZIPEPUBResourceReader(fileURL: zip)
        let slash = EPUBPath(relativePath: "literal%2Fname.txt", fragment: nil)
        let dots = EPUBPath(relativePath: "literal%2e%2e.txt", fragment: nil)
        #expect(try reader.readExactResource(slash, maxBytes: 64) == Data("slash-literal".utf8))
        #expect(try reader.readExactResource(dots, maxBytes: 64) == Data("dot-literal".utf8))
        #expect(try reader.contains(EPUBPath(relativePath: "literal/name.txt", fragment: nil)) == false)
    }

    @Test
    func directoryAndZipBudgetsFailClosedBeforeReturningPartialBytes() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("directory.epub", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4_096).write(to: directory.appendingPathComponent("large.bin"))
        let directoryReader = try DirectoryEPUBResourceReader(root: directory)
        #expect(throws: EPUBResourceError.resourceTooLarge) {
            _ = try directoryReader.readExactResource(EPUBPath(relativePath: "large.bin", fragment: nil), maxBytes: 64)
        }

        let zip = root.appendingPathComponent("bomb.epub")
        try Self.makeZip(at: zip, entries: [.file("large.bin", Data(repeating: 0x41, count: 4_096), .deflate)])
        let zipReader = try ZIPEPUBResourceReader(fileURL: zip)
        #expect(throws: EPUBResourceError.resourceTooLarge) {
            _ = try zipReader.readExactResource(EPUBPath(relativePath: "large.bin", fragment: nil), maxBytes: 64)
        }

        try Self.patchFirstCentralDirectoryUncompressedSize(in: zip, to: 1)
        let mismatched = try ZIPEPUBResourceReader(fileURL: zip)
        #expect(throws: EPUBResourceError.resourceTooLarge) {
            _ = try mismatched.readExactResource(EPUBPath(relativePath: "large.bin", fragment: nil), maxBytes: 64)
        }
    }

    @Test
    func hostileZipNamespaceDuplicateSymlinkAndEntryCountAreRejected() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for (name, entries) in [
            ("traversal.epub", [ZipEntry.file("../escape.txt", Data("x".utf8), .none)]),
            ("absolute.epub", [ZipEntry.file("/absolute.txt", Data("x".utf8), .none)]),
            ("backslash.epub", [ZipEntry.file("folder\\file.txt", Data("x".utf8), .none)]),
            ("symlink.epub", [ZipEntry.symlink("link", "../outside")]),
            ("directory-entry.epub", [ZipEntry.directory("folder/")]),
        ] {
            let url = root.appendingPathComponent(name)
            try Self.makeZip(at: url, entries: entries)
            do {
                _ = try ZIPEPUBResourceReader(fileURL: url)
                Issue.record("hostile archive should fail closed")
            } catch {
                #expect(error as? EPUBResourceError == .unsafeResource)
                #expect(String(describing: error).contains("escape.txt") == false)
                #expect(String(describing: error).contains("outside") == false)
            }
        }

        let duplicate = root.appendingPathComponent("duplicate.epub")
        try Self.makeZip(at: duplicate, entries: [
            .file("same.txt", Data("one".utf8), .none),
            .file("same.txt", Data("two".utf8), .none),
        ])
        #expect(throws: EPUBResourceError.ambiguousResource) {
            _ = try ZIPEPUBResourceReader(fileURL: duplicate)
        }

        let many = root.appendingPathComponent("many.epub")
        try Self.makeZip(at: many, entries: [
            .file("1.txt", Data(), .none),
            .file("2.txt", Data(), .none),
            .file("3.txt", Data(), .none),
        ])
        #expect(throws: EPUBResourceError.tooManyEntries) {
            _ = try ZIPEPUBResourceReader(fileURL: many, maximumEntryCount: 2)
        }
    }

    @Test
    func resolverPrefersCurrentDirectoryThenUsesOnlyExactBasenamePackedFallback() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current").appendingPathComponent("book.epub", isDirectory: true)
        let supplementalRoot = root.appendingPathComponent("supplemental", isDirectory: true)
        try FileManager.default.createDirectory(at: supplementalRoot, withIntermediateDirectories: true)
        try Self.writeMinimalEPUBDirectory(at: current, chapterText: "directory wins")
        let packed = supplementalRoot.appendingPathComponent("book.epub")
        try Self.makeMinimalEPUBZip(at: packed, chapterText: "packed fallback")

        let configuration = try Self.configuration(epubRoot: supplementalRoot, under: root)
        let libraryURL = root.appendingPathComponent("current.sqlite")
        let currentBook = try Self.book(path: current.path, under: libraryURL)
        let currentReader = try EPUBSourceResolver.reader(for: currentBook, configuration: configuration)
        #expect(try BookContent(reader: currentReader).getChapter("chapter") == "directory wins")

        try FileManager.default.removeItem(at: current)
        let fallbackReader = try EPUBSourceResolver.reader(for: currentBook, configuration: configuration)
        #expect(try BookContent(reader: fallbackReader).getChapter("chapter") == "packed fallback")

        let annotationsURL = root.appendingPathComponent("annotations.sqlite")
        try Self.emptyDatabase(at: annotationsURL)
        let books = try AppleBooks(
            libraryDB: libraryURL,
            annotationsDB: annotationsURL,
            configurationFile: root.appendingPathComponent("config.json")
        )
        #expect(try books.bookContent(forBookLocalPK: 1).getChapter("chapter") == "packed fallback")

        let symlinkRoot = root.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createDirectory(at: symlinkRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot.appendingPathComponent("book.epub"),
            withDestinationURL: packed
        )
        let symlinkConfiguration = try Self.configuration(epubRoot: symlinkRoot, under: root, name: "symlink-config.json")
        #expect(throws: ContentError.unavailable(.missing)) {
            _ = try EPUBSourceResolver.reader(for: currentBook, configuration: symlinkConfiguration)
        }

        let realPrimary = root.appendingPathComponent("real-primary.epub", isDirectory: true)
        try Self.writeMinimalEPUBDirectory(at: realPrimary, chapterText: "unsafe primary")
        let linkedPrimary = root.appendingPathComponent("book.epub")
        try FileManager.default.createSymbolicLink(at: linkedPrimary, withDestinationURL: realPrimary)
        let linkedBook = try Self.book(path: linkedPrimary.path, under: root.appendingPathComponent("linked.sqlite"))
        #expect(throws: EPUBResourceError.unsafeResource) {
            _ = try EPUBSourceResolver.reader(for: linkedBook, configuration: configuration)
        }

        let wrongNameRoot = root.appendingPathComponent("wrong", isDirectory: true)
        try FileManager.default.createDirectory(at: wrongNameRoot, withIntermediateDirectories: true)
        try Self.makeMinimalEPUBZip(at: wrongNameRoot.appendingPathComponent("other.epub"), chapterText: "wrong")
        let wrongConfiguration = try Self.configuration(epubRoot: wrongNameRoot, under: root, name: "wrong-config.json")
        #expect(throws: ContentError.unavailable(.missing)) {
            _ = try EPUBSourceResolver.reader(for: currentBook, configuration: wrongConfiguration)
        }

        let noRootConfiguration = try AppleBooksConfiguration(fileURL: root.appendingPathComponent("missing-config.json"))
        #expect(throws: ContentError.unavailable(.missing)) {
            _ = try EPUBSourceResolver.reader(for: currentBook, configuration: noRootConfiguration)
        }
    }

    private enum ZipEntry {
        case file(String, Data, CompressionMethod)
        case symlink(String, String)
        case directory(String)
    }

    private final class LogicalEPUBFixture {
        let root: URL
        let directoryURL: URL
        let zipURL: URL

        init() throws {
            root = try SupplementalEPUBTests.temporaryDirectory()
            directoryURL = root.appendingPathComponent("directory.epub", isDirectory: true)
            zipURL = root.appendingPathComponent("packed.epub")
            let resources = SupplementalEPUBTests.logicalResources(chapterText: "Before <span id=\"part\">Visible <em>chapter</em></span> After")
            try SupplementalEPUBTests.writeResources(resources, to: directoryURL)
            try SupplementalEPUBTests.makeZip(at: zipURL, entries: resources.sorted(by: { $0.key < $1.key }).map {
                .file($0.key, $0.value, .deflate)
            })
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func logicalResources(chapterText: String) -> [String: Data] {
        [
            "META-INF/container.xml": Data("<container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/package.opf\"/></rootfiles></container>".utf8),
            "OPS/package.opf": Data("""
            <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/">
              <metadata><dc:title>Fixture</dc:title><dc:creator>Author</dc:creator><dc:language>en</dc:language></metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
                <item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/>
              </manifest>
              <spine><itemref idref="chapter"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><nav epub:type=\"toc\"><ol><li><a href=\"chapter.xhtml#part\">Chapter</a></li></ol></nav></body></html>".utf8),
            "OPS/chapter.xhtml": Data("<html><body>\(chapterText)</body></html>".utf8),
            "OPS/cover.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01]),
        ]
    }

    private static func writeMinimalEPUBDirectory(at root: URL, chapterText: String) throws {
        try writeResources(logicalResources(chapterText: "<span id=\"part\">\(chapterText)</span>"), to: root)
    }

    private static func makeMinimalEPUBZip(at url: URL, chapterText: String) throws {
        let resources = logicalResources(chapterText: "<span id=\"part\">\(chapterText)</span>")
        try makeZip(at: url, entries: resources.sorted(by: { $0.key < $1.key }).map {
            .file($0.key, $0.value, .deflate)
        })
    }

    private static func writeResources(_ resources: [String: Data], to root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, data) in resources {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
    }

    private static func makeZip(at url: URL, entries: [ZipEntry]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for entry in entries {
            switch entry {
            case let .file(path, data, compression):
                try archive.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: compression
                ) { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return start < end ? data.subdata(in: start..<end) : Data()
                }
            case let .symlink(path, target):
                let data = Data(target.utf8)
                try archive.addEntry(with: path, type: .symlink, uncompressedSize: Int64(data.count)) { position, size in
                    let start = Int(position)
                    let end = min(start + size, data.count)
                    return start < end ? data.subdata(in: start..<end) : Data()
                }
            case let .directory(path):
                try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
            }
        }
    }

    private static func patchFirstCentralDirectoryUncompressedSize(in url: URL, to value: UInt32) throws {
        var data = try Data(contentsOf: url)
        let signature = Data([0x50, 0x4B, 0x01, 0x02])
        guard let range = data.range(of: signature) else { throw EPUBResourceError.invalidArchive }
        let offset = range.lowerBound + 24
        guard offset + 4 <= data.count else { throw EPUBResourceError.invalidArchive }
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.replaceSubrange(offset..<(offset + 4), with: bytes)
        }
        try data.write(to: url)
    }

    private static func configuration(epubRoot: URL, under root: URL, name: String = "config.json") throws -> AppleBooksConfiguration {
        let file = root.appendingPathComponent(name)
        let data = try JSONSerialization.data(withJSONObject: ["epub_root": epubRoot.path])
        try data.write(to: file)
        return try AppleBooksConfiguration(fileURL: file)
    }

    private static func emptyDatabase(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw EPUBResourceError.unreadableResource
        }
        sqlite3_close(handle)
    }

    private static func book(path: String, under databaseURL: URL) throws -> Book {
        var handle: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &handle) == SQLITE_OK, let handle else {
            throw EPUBResourceError.unreadableResource
        }
        defer { sqlite3_close(handle) }
        let sql = "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZPATH TEXT); INSERT INTO ZBKLIBRARYASSET VALUES(1,?);"
        guard sqlite3_exec(handle, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZPATH TEXT);", nil, nil, nil) == SQLITE_OK else {
            throw EPUBResourceError.unreadableResource
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "INSERT INTO ZBKLIBRARYASSET VALUES(1,?);", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw EPUBResourceError.unreadableResource }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw EPUBResourceError.unreadableResource }
        _ = sql
        return try #require(try BookQueries(connection: SQLiteConnection.readOnly(path: databaseURL.path)).getForContent(1))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

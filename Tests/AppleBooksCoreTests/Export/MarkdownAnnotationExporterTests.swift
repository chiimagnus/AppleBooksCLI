import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Suite("MarkdownAnnotationExporterTests")
struct MarkdownAnnotationExporterTests {
    @Test
    func singleAssetPreservesQuoteNoteStructureAndEscapesMarkdown() {
        let annotation = makeAnnotation(
            localPK: 1,
            assetID: "book",
            selectedText: "a*b_[c](d)#e+f!g|h\\i\r\nsecond",
            note: "note `{x}` <tag>"
        )

        let markdown = MarkdownAnnotationExporter.render(
            assetID: "book#[1]",
            annotations: [annotation]
        )

        #expect(markdown == ##"""
        # Annotations for book\#\[1\]

        > a\*b\_\[c\]\(d\)\#e\+f\!g\|h\\i
        > second

        **Note:** note \`\{x\}\` \<tag\>
        
        """##)
    }

    @Test
    func allExportOrdersUnknownAssetAndNullCreationFirstThenLocalPK() {
        let late = Date(timeIntervalSince1970: 20)
        let early = Date(timeIntervalSince1970: 10)
        let annotations = [
            makeAnnotation(localPK: 9, assetID: "b", createdAt: early, selectedText: "b"),
            makeAnnotation(localPK: 4, assetID: "a", createdAt: early, selectedText: "a-4"),
            makeAnnotation(localPK: 3, assetID: "a", createdAt: early, selectedText: "a-3"),
            makeAnnotation(localPK: 2, assetID: "a", createdAt: late, selectedText: "a-late"),
            makeAnnotation(localPK: 1, assetID: "a", createdAt: nil, selectedText: "a-null"),
            makeAnnotation(localPK: 8, assetID: nil, createdAt: late, selectedText: "unknown"),
        ]

        let markdown = MarkdownAnnotationExporter.renderAll(annotations)

        #expect(markdown.firstRange(of: #"## \(unknown\)"#)!.lowerBound < markdown.firstRange(of: "## a")!.lowerBound)
        #expect(markdown.firstRange(of: "> a-null")!.lowerBound < markdown.firstRange(of: "> a-3")!.lowerBound)
        #expect(markdown.firstRange(of: "> a-3")!.lowerBound < markdown.firstRange(of: "> a-4")!.lowerBound)
        #expect(markdown.firstRange(of: "> a-4")!.lowerBound < markdown.firstRange(of: "> a-late")!.lowerBound)
        #expect(markdown.firstRange(of: "## a")!.lowerBound < markdown.firstRange(of: "## b")!.lowerBound)
    }

    @Test
    func emptyExportsKeepSourceVisibleEmptyState() {
        #expect(MarkdownAnnotationExporter.renderAll([]) == "# Annotations export\n\n_No annotations._\n")
        #expect(
            MarkdownAnnotationExporter.render(assetID: "asset", annotations: [])
                == "# Annotations for asset\n\n_No annotations._\n"
        )
    }

    @Test
    func emptyUserBlockDoesNotLeakOtherAnnotationFields() {
        let annotation = makeAnnotation(
            localPK: 7,
            assetID: "asset",
            selectedText: nil,
            note: nil,
            representativeText: "must-not-leak",
            uuid: "uuid-must-not-leak"
        )

        let markdown = MarkdownAnnotationExporter.render(assetID: "asset", annotations: [annotation])

        #expect(markdown == "# Annotations for asset\n\n\n")
        #expect(markdown.contains("must-not-leak") == false)
        #expect(markdown.contains("uuid-must-not-leak") == false)
    }

    @Test
    func facadeUsesCanonicalUserScopeAndKeepsOrphans() throws {
        let fixture = try FacadeFixture()
        defer { fixture.remove() }

        let all = try fixture.books.exportAnnotationsMarkdown()
        #expect(all.contains("orphan-user"))
        #expect(all.contains("book-b-user"))
        #expect(all.contains("unknown-asset-user"))
        #expect(all.contains("system-bookmark") == false)
        #expect(all.contains("deleted-user") == false)
        #expect(all.contains("unknown-deleted") == false)
        #expect(all.firstRange(of: #"## \(unknown\)"#)!.lowerBound < all.firstRange(of: "## asset-a")!.lowerBound)
        #expect(all.firstRange(of: "## asset-a")!.lowerBound < all.firstRange(of: "## asset-b")!.lowerBound)

        let byAsset = try fixture.books.exportAnnotationsMarkdown(bookAssetID: "asset-a")
        #expect(byAsset.hasPrefix("# Annotations for asset-a\n\n"))
        #expect(byAsset.contains("orphan-user"))
        #expect(byAsset.contains("system-bookmark") == false)
        #expect(byAsset.contains("book-b-user") == false)
    }

    private func makeAnnotation(
        localPK: Int64,
        assetID: String?,
        createdAt: Date? = nil,
        selectedText: String? = nil,
        note: String? = nil,
        representativeText: String? = nil,
        uuid: String? = nil
    ) -> Annotation {
        Annotation(
            localPK: localPK,
            uuid: uuid,
            rawAssetID: assetID,
            isDeleted: false,
            isUnderline: nil,
            style: nil,
            type: 1,
            createdAt: createdAt,
            modifiedAt: nil,
            representativeText: representativeText,
            selectedText: selectedText,
            note: note,
            location: nil,
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil
        )
    }

    private final class FacadeFixture {
        let root: URL
        let books: AppleBooks

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let annotations = root.appendingPathComponent("annotations.sqlite")
            let library = root.appendingPathComponent("library.sqlite")
            let config = root.appendingPathComponent("config.json")

            try Self.createDatabase(annotations, sql: """
            CREATE TABLE ZAEANNOTATION(
                Z_PK INTEGER PRIMARY KEY,
                ZANNOTATIONASSETID TEXT,
                ZANNOTATIONSELECTEDTEXT TEXT,
                ZANNOTATIONNOTE TEXT,
                ZANNOTATIONCREATIONDATE REAL,
                ZANNOTATIONDELETED INTEGER,
                ZANNOTATIONTYPE INTEGER
            );
            INSERT INTO ZAEANNOTATION VALUES
                (1,'asset-b','book-b-user',NULL,20,0,1),
                (2,'asset-a','system-bookmark',NULL,10,0,3),
                (3,'asset-a','orphan-user',NULL,NULL,0,1),
                (4,'asset-a','deleted-user',NULL,5,1,1),
                (5,'asset-a','unknown-deleted',NULL,5,NULL,1),
                (6,NULL,'unknown-asset-user',NULL,30,0,1);
            """)
            try Self.createDatabase(
                library,
                sql: "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT);"
            )
            try Data("{\"historical_assets\":{}}".utf8).write(to: config)

            books = try AppleBooks(
                libraryDB: library,
                annotationsDB: annotations,
                historicalConfig: config
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
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
    }
}

import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ExportFileWriterTests")
struct ExportFileWriterTests {
    @Test
    func neverIsDefaultAlwaysReplacesAndAtomicWritesLeaveNoTemporaryFile() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)

        let created = try writer.write(Data("first".utf8), fileName: "report.json")
        #expect(created.disposition == .created)
        #expect(try String(contentsOf: created.destination, encoding: .utf8) == "first")
        #expect(throws: ExportFileWriterError.destinationExists) {
            _ = try writer.write(Data("second".utf8), fileName: "report.json")
        }
        #expect(try String(contentsOf: created.destination, encoding: .utf8) == "first")

        let updated = try writer.write(
            Data("second".utf8),
            fileName: "report.json",
            overwrite: .always
        )
        #expect(updated.disposition == .updated)
        #expect(try String(contentsOf: updated.destination, encoding: .utf8) == "second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasSuffix(".part") } == false)
    }

    @Test
    func alwaysPublishesIdenticalDataAndPreservesNewJSONTimestampBytes() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let original = Data(#"{"exportedAt":"2026-01-01T00:00:00Z","body":"same"}"#.utf8)
        let newer = Data(#"{"exportedAt":"2026-09-01T00:00:00Z","body":"same"}"#.utf8)
        let first = try writer.write(original, fileName: "export.json")
        let originalInode = try FileManager.default.attributesOfItem(atPath: first.destination.path)[.systemFileNumber] as? NSNumber
        let repeated = try writer.write(original, fileName: "export.json", overwrite: .always)
        let replacedInode = try FileManager.default.attributesOfItem(atPath: first.destination.path)[.systemFileNumber] as? NSNumber
        #expect(originalInode != nil && replacedInode != nil && originalInode != replacedInode)
        #expect(repeated.disposition == .updated)
        let updated = try writer.write(newer, fileName: "export.json", overwrite: .always)
        #expect(updated.disposition == .updated)
        #expect(try Data(contentsOf: updated.destination) == newer)
    }

    @Test
    func derivedNamesStaySingleComponentsBoundedAndCollisionsReceiveStableSuffixes() throws {
        let hostile = " ../A/B:C\0\n.. "
        let safe = ExportPathComponent.safe(hostile)
        #expect(safe.contains("/") == false)
        #expect(safe.contains(":") == false)
        #expect(safe.contains("\0") == false)
        #expect(safe.contains("\n") == false)
        #expect(safe.hasPrefix(".") == false)
        #expect(safe.hasSuffix(".") == false)
        #expect(safe.lengthOfBytes(using: .utf8) <= ExportPathComponent.maximumUTF8Bytes)
        #expect(ExportPathComponent.safe(".") == "%2E")
        #expect(ExportPathComponent.safe("..") == "%2E%2E")

        var allocator = ExportFilenameAllocator()
        #expect(allocator.allocate(derivedFrom: "Same", extension: "md") == "Same.md")
        #expect(allocator.allocate(derivedFrom: "Same", extension: "md") == "Same-2.md")

        let long = String(repeating: "界", count: 100)
        #expect(ExportPathComponent.safe(long).lengthOfBytes(using: .utf8) <= ExportPathComponent.maximumUTF8Bytes)
    }

    @Test
    func genericPerDocumentWriterOwnsSafeNamesCollisionsAndExtensionValidation() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.bundleWithDuplicateTitles(cover: FixtureFactory.pngCover)

        let result = try writer.writeDocuments(bundle, fileExtension: "json") { group in
            Data("records=\(group.records.count)".utf8)
        }
        #expect(result.documentFileCount == 2)
        #expect(result.files.map(\.lastPathComponent) == ["Same.json", "Same-2.json"])
        #expect(try result.files.map { try String(contentsOf: $0, encoding: .utf8) } == ["records=1", "records=1"])

        #expect(throws: ExportFileWriterError.invalidFileName) {
            _ = try writer.writeDocuments(bundle, fileExtension: "../json") { _ in Data() }
        }
    }

    @Test
    func traversalInvalidNamesAndSymlinkDestinationsFailClosed() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)

        for name in ["../escape.md", ".hidden", "bad:name.md", "bad/name.md", "bad\\name.md", " trailing.md "] {
            #expect(throws: ExportFileWriterError.invalidFileName) {
                _ = try writer.write(Data("x".utf8), fileName: name)
            }
        }

        let outside = fixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let symlink = fixture.output.appendingPathComponent("report.md")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try writer.write(Data("new".utf8), fileName: "report.md", overwrite: .always)
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")
    }

    @Test
    func symlinkOutputRootAndAttachmentParentAreRejectedWithoutFollowingThem() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let outsideDirectory = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: false)
        let rootLink = fixture.root.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(outputRoot: rootLink)
        }
        let parentLink = fixture.root.appendingPathComponent("parent-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(outputRoot: parentLink.appendingPathComponent("new-output", isDirectory: true))
        }
        let realNested = outsideDirectory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: realNested, withIntermediateDirectories: false)
        let ancestorLink = fixture.root.appendingPathComponent("ancestor-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: outsideDirectory)
        #expect(throws: ExportFileWriterError.unsafeOutputRoot) {
            _ = try ExportFileWriter(
                outputRoot: ancestorLink
                    .appendingPathComponent("nested", isDirectory: true)
                    .appendingPathComponent("new-output", isDirectory: true)
            )
        }

        let attachments = fixture.output.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: attachments, withDestinationURL: outsideDirectory)
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.bundle(
            title: "Cover",
            author: "Author",
            cover: FixtureFactory.pngCover
        )
        #expect(throws: ExportFileWriterError.unsafeParent) {
            _ = try writer.writeMarkdown(
                bundle,
                layout: .perBook,
                coverMode: .file
            )
        }
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path)) == ["nested"])
    }

    @Test
    func fileCoversUseRealMediaTypesAndSameNameDocumentsAndCoversNeverOverwriteEachOther() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.bundleWithDuplicateTitles(cover: FixtureFactory.pngCover)

        let result = try writer.writeMarkdown(
            bundle,
            layout: .perBook,
            coverMode: .file
        )
        #expect(result.documentFileCount == 2)
        let names = result.files.map(\.lastPathComponent)
        #expect(names.contains("Same.md"))
        #expect(names.contains("Same-2.md"))
        #expect(names.contains("Same-cover.png"))
        #expect(names.contains("Same-cover-2.png"))
        #expect(names.contains(where: { $0.hasSuffix(".jpg") }) == false)

        let firstBook = try String(contentsOf: fixture.output.appendingPathComponent("Same.md"), encoding: .utf8)
        let secondBook = try String(contentsOf: fixture.output.appendingPathComponent("Same-2.md"), encoding: .utf8)
        #expect(firstBook.contains("![Cover](<Attachments/Same-cover.png>)"))
        #expect(secondBook.contains("![Cover](<Attachments/Same-cover-2.png>)"))
    }

    @Test
    func inlineCoverUsesDeclaredMediaTypeWithoutWritingAttachment() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.bundle(
            title: "Inline",
            author: nil,
            cover: FixtureFactory.pngCover
        )

        _ = try writer.writeMarkdown(
            bundle,
            layout: .perBook,
            coverMode: .inline
        )
        let markdown = try String(contentsOf: fixture.output.appendingPathComponent("Inline.md"), encoding: .utf8)
        #expect(markdown.contains("![Cover](data:image/png;base64,"))
        #expect(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Attachments").path) == false)
    }

    @Test
    func unsupportedCoverMediaTypeFailsInsteadOfInventingExtension() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let cover = EPUBCover(
            data: Data("unknown".utf8),
            declaredMediaType: "application/octet-stream",
            detectedMediaType: nil,
            source: .metadataID
        )
        let bundle = FixtureFactory.bundle(title: "Unknown Cover", author: nil, cover: cover)

        #expect(throws: ExportFileWriterError.unsupportedCoverMediaType) {
            _ = try writer.writeMarkdown(
                bundle,
                layout: .perBook,
                coverMode: .file
            )
        }
    }

    @Test
    func countOnlyWritersMatchLegacyArtifactsWithoutReturningPaths() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let bundle = FixtureFactory.bundleWithDuplicateTitles(cover: FixtureFactory.pngCover)
        let legacy = try ExportFileWriter(outputRoot: fixture.output.appendingPathComponent("legacy"))
        let canonical = try ExportFileWriter(outputRoot: fixture.output.appendingPathComponent("canonical"))
        let result = try legacy.writeMarkdown(bundle, layout: .perBook, coverMode: .file)
        let count = try canonical.writeMarkdownCount(bundle, layout: .perBook, coverMode: .file)
        #expect(count == 2)
        #expect(result.documentFileCount == count)
        #expect(result.files.count == 4)
        for path in result.files {
            let relative = String(path.path.dropFirst(legacy.outputRoot.path.count + 1))
            #expect(try Data(contentsOf: path) == Data(contentsOf: canonical.outputRoot.appendingPathComponent(relative)))
        }
        let json = try canonical.writeDocumentsCount(bundle, fileExtension: "json") { _ in Data("{}".utf8) }
        #expect(json == count)
    }

    @Test
    func countOnlyDocumentTraversalKeepsScalarResultsForLargeExports() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let groups = (0..<100_001).map { index in
            ExportGroup(source: .epubUnmapped(assetID: "synthetic-\(index)"), records: [])
        }
        let bundle = FixtureFactory.makeBundle(groups: groups)
        var materialized = 0
        let count = try writer.forEachDocument(bundle, fileExtension: "md") { _, fileName in
            #expect(fileName == "synthetic-\(materialized).md")
            materialized += 1
        }
        #expect(count == 100_001)
        #expect(materialized == count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).isEmpty)
    }

    @Test
    func destinationNodeTypeDependsOnlyOnGroupingAndNeverRefusesEveryExistingNode() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let file = fixture.output.appendingPathComponent("file")
        try Data("original".utf8).write(to: file)
        let directory = fixture.output.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = fixture.output.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        for target in [file, directory, link] {
            for grouping in [ExportFileGrouping.single, .perBook] {
                #expect(throws: ExportFileWriterError.destinationExists) {
                    try ExportFileWriter.validateDestination(target, grouping: grouping, overwrite: .never)
                }
            }
        }
        for (target, grouping) in [(file, ExportFileGrouping.perBook), (directory, .single), (link, .single)] {
            #expect(throws: ExportFileWriterError.unsafeDestination) {
                try ExportFileWriter.validateDestination(target, grouping: grouping, overwrite: .always)
            }
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "original")
        for invalid in [".", "..", "/", "directory/.", "directory/..", ".applebookscli-export-v1"] {
            #expect(throws: ExportFileWriterError.invalidFileName) {
                _ = try ExportFileWriter.destination(path: invalid, currentDirectory: fixture.output)
            }
        }
        let relative = try ExportFileWriter.destination(path: "new", currentDirectory: fixture.output)
        #expect(relative == fixture.output.appendingPathComponent("new").standardizedFileURL)
    }

    private final class FileFixture {
        let root: URL
        let output: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private enum FixtureFactory {
        static let pngCover = EPUBCover(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00]),
            declaredMediaType: "image/png",
            detectedMediaType: "image/png",
            source: .manifestProperty
        )

        static func bundle(
            title: String,
            author: String?,
            note: String = "note",
            cover: EPUBCover? = nil
        ) -> ExportBundle {
            let book = makeBook(pk: 1, title: title, author: author)
            let group = ExportGroup(
                source: .epubCurrent(book),
                records: [makeRecord(pk: 1, book: book, note: note)],
                epubCover: cover
            )
            return makeBundle(groups: [group])
        }

        static func bundleWithDuplicateTitles(cover: EPUBCover) -> ExportBundle {
            let first = makeBook(pk: 1, title: "Same", author: nil)
            let second = makeBook(pk: 2, title: "Same", author: nil)
            return makeBundle(groups: [
                ExportGroup(source: .epubCurrent(first), records: [makeRecord(pk: 1, book: first)], epubCover: cover),
                ExportGroup(source: .epubCurrent(second), records: [makeRecord(pk: 2, book: second)], epubCover: cover),
            ])
        }

        static func makeBundle(groups: [ExportGroup]) -> ExportBundle {
            let count = groups.reduce(0) { $0 + $1.records.count }
            return ExportBundle(
                options: try! ExportOptions(source: .epub, hasHighlight: true),
                groups: groups,
                warnings: [],
                statistics: ExportStatistics(
                    documentCount: groups.count,
                    epubDocumentCount: groups.count,
                    pdfDocumentCount: 0,
                    recordCount: count,
                    epubAnnotationCount: count,
                    pdfHighlightCount: 0,
                    highlightCount: count,
                    noteCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: 0
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: groups.count,
                    epubAnnotationCount: count,
                    pdfAttemptedDocumentCount: 0,
                    pdfSucceededDocumentCount: 0,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: 0
                )
            )
        }

        private static func makeBook(pk: Int64, title: String, author: String?) -> Book {
            Book(
                localPK: pk,
                assetID: "asset-\(pk)",
                title: title,
                author: author,
                description: nil,
                epubID: nil,
                genre: nil,
                genresRaw: nil,
                comments: nil,
                language: nil,
                year: 2024,
                contentType: 1,
                pageCount: nil,
                path: nil,
                fileSize: nil,
                coverURL: nil,
                isFinished: nil,
                readingProgressRaw: nil,
                durationRawMilliseconds: nil,
                creationDate: nil,
                modificationDate: nil,
                finishedDate: nil,
                lastOpenDate: nil,
                purchaseDate: nil,
                releaseDate: nil,
                isExplicit: nil,
                isLocked: nil,
                isEphemeral: nil,
                isHidden: nil,
                isSample: nil,
                isStoreAudiobook: nil,
                rating: nil
            )
        }

        private static func makeRecord(pk: Int64, book: Book, note: String = "note") -> ExportRecord {
            let annotation = Annotation(
                localPK: pk,
                uuid: "uuid-\(pk)",
                rawAssetID: book.assetID,
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: "quote-\(pk)",
                note: note,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            return ExportRecord(payload: .epub(EnrichedAnnotation(annotation: annotation, source: .currentLibrary(book))))
        }
    }
}

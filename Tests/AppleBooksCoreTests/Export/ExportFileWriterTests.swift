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
    func smartIgnoresRunOnlyJSONTimestampButDetectsStableContentChange() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let first = Data(#"{"exportedAt":"2026-01-01T00:00:00Z","body":"same"}"#.utf8)
        let second = Data(#"{"exportedAt":"2026-09-01T00:00:00Z","body":"same"}"#.utf8)
        let changed = Data(#"{"exportedAt":"2026-09-01T00:00:00Z","body":"changed"}"#.utf8)
        let nestedFirst = Data(#"{"exportedAt":"2026-01-01T00:00:00Z","payload":{"exported":"one"}}"#.utf8)
        let nestedChanged = Data(#"{"exportedAt":"2026-09-01T00:00:00Z","payload":{"exported":"two"}}"#.utf8)

        _ = try writer.write(first, fileName: "export.json")
        let unchanged = try writer.write(second, fileName: "export.json", overwrite: .smart)
        #expect(unchanged.disposition == .unchanged)
        #expect(try Data(contentsOf: unchanged.destination) == first)

        let updated = try writer.write(changed, fileName: "export.json", overwrite: .smart)
        #expect(updated.disposition == .updated)
        #expect(try Data(contentsOf: updated.destination) == changed)

        _ = try writer.write(nestedFirst, fileName: "nested.json")
        let nestedUpdated = try writer.write(nestedChanged, fileName: "nested.json", overwrite: .smart)
        #expect(nestedUpdated.disposition == .updated)
        #expect(try Data(contentsOf: nestedUpdated.destination) == nestedChanged)
    }

    @Test
    func smartMarkdownNormalizationOnlyIgnoresFrontmatterRunMetadata() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let first = Data("---\nexported_at: \"one\"\n---\nexported: body-one\n".utf8)
        let timestampOnly = Data("---\nexported_at: \"two\"\n---\nexported: body-one\n".utf8)
        let bodyChanged = Data("---\nexported_at: \"three\"\n---\nexported: body-two\n".utf8)

        _ = try writer.write(first, fileName: "normalized.md")
        let unchanged = try writer.write(timestampOnly, fileName: "normalized.md", overwrite: .smart)
        #expect(unchanged.disposition == .unchanged)
        #expect(try Data(contentsOf: unchanged.destination) == first)
        let updated = try writer.write(bodyChanged, fileName: "normalized.md", overwrite: .smart)
        #expect(updated.disposition == .updated)
        #expect(try Data(contentsOf: updated.destination) == bodyChanged)
    }

    @Test
    func markdownSmartHashOmitsSelfReferenceAndOnlyUpdatesExportedAtOnRealWrite() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        var currentDate = Date(timeIntervalSince1970: 1_700_000_000.125)
        let writer = try ExportFileWriter(outputRoot: fixture.output, now: { currentDate })
        let baseOptions = ObsidianMarkdownOptions(extendedFrontmatter: true, customTags: ["one"])
        let firstProfile = MarkdownProfile(syntax: .obsidian, options: baseOptions)
        let bundle = FixtureFactory.bundle(title: "Smart", author: "Author", note: "same")

        let created = try writer.writeMarkdown(
            bundle,
            layout: .single(fileName: "smart.md"),
            profile: firstProfile,
            overwrite: .never
        )
        #expect(created.documentFileCount == 1)
        let file = try #require(created.files.first)
        let firstText = try String(contentsOf: file, encoding: .utf8)
        #expect(firstText.contains("last-import-hash: \"") == true)
        #expect(firstText.contains("exported_at: \"2023-11-14T22:13:20.125Z\"") == true)

        currentDate = Date(timeIntervalSince1970: 1_800_000_000.5)
        let unchanged = try writer.writeMarkdown(
            bundle,
            layout: .single(fileName: "smart.md"),
            profile: firstProfile,
            overwrite: .smart
        )
        #expect(unchanged.files == [file])
        #expect(try String(contentsOf: file, encoding: .utf8) == firstText)

        let changedProfile = MarkdownProfile(
            syntax: .obsidian,
            options: ObsidianMarkdownOptions(extendedFrontmatter: true, customTags: ["two"])
        )
        _ = try writer.writeMarkdown(
            bundle,
            layout: .single(fileName: "smart.md"),
            profile: changedProfile,
            overwrite: .smart
        )
        let changedText = try String(contentsOf: file, encoding: .utf8)
        #expect(changedText != firstText)
        #expect(changedText.contains("exported_at: \"2027-01-15T08:00:00.500Z\"") == true)
        #expect(changedText.contains("  - \"two\"") == true)
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
        #expect(result.warnings.isEmpty)
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
                profile: .plain,
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
            profile: .plain,
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
            profile: .plain,
            coverMode: .inline
        )
        let markdown = try String(contentsOf: fixture.output.appendingPathComponent("Inline.md"), encoding: .utf8)
        #expect(markdown.contains("![Cover](data:image/png;base64,"))
        #expect(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("Attachments").path) == false)
    }

    @Test
    func authorPagesReuseTheSameSafePathOwnerAndFailureDoesNotRollbackBooks() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let author = "A]]|#^/.."
        let bundle = FixtureFactory.bundle(title: "Book", author: author)
        let options = ObsidianMarkdownOptions(authorLinks: true, authorPages: true)
        let profile = MarkdownProfile(syntax: .obsidian, options: options)
        let authorStem = ExportPathComponent.safe(author, fallback: "Unknown")
        let authors = fixture.output.appendingPathComponent("Authors", isDirectory: true)
        try FileManager.default.createDirectory(at: authors, withIntermediateDirectories: false)
        let existingAuthor = authors.appendingPathComponent("\(authorStem).md")
        try Data("existing author page".utf8).write(to: existingAuthor)
        let writer = try ExportFileWriter(outputRoot: fixture.output)

        let result = try writer.writeMarkdown(
            bundle,
            layout: .perBook,
            profile: profile,
            overwrite: .never
        )
        #expect(result.documentFileCount == 1)
        #expect(result.warnings == [.authorPageFailed])
        let bookURL = fixture.output.appendingPathComponent("Book.md")
        #expect(FileManager.default.fileExists(atPath: bookURL.path))
        let book = try String(contentsOf: bookURL, encoding: .utf8)
        #expect(book.contains("[[Authors/\(authorStem)|\(authorStem)]]"))
        #expect(try String(contentsOf: existingAuthor, encoding: .utf8) == "existing author page")
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
                profile: .plain,
                coverMode: .file
            )
        }
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

        private static func makeBundle(groups: [ExportGroup]) -> ExportBundle {
            let count = groups.reduce(0) { $0 + $1.records.count }
            return ExportBundle(
                options: try! ExportOptions(source: .epub, kinds: [.highlight]),
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
                    bookmarkCount: 0,
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

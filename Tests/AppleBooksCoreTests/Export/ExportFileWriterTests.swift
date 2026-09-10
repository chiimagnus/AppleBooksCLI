import CryptoKit
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
    func incrementalRenderFailureCleansTemporaryFileAndPreservesDestination() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let destination = fixture.output.appendingPathComponent("report.json")
        try Data("original".utf8).write(to: destination)

        #expect(throws: FixtureError.stopped) {
            _ = try writer.writeIncrementally(
                fileName: "report.json",
                overwrite: .always
            ) { sink in
                try sink(Data("partial".utf8))
                throw FixtureError.stopped
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).contains { $0.hasSuffix(".part") } == false)
    }

    @Test
    func descriptorRelativePublishFailsClosedAcrossParentAndDestinationRaces() throws {
        let parentFixture = try FileFixture()
        defer { parentFixture.remove() }
        let parentWriter = try ExportFileWriter(outputRoot: parentFixture.output)
        let heldOutput = parentFixture.root.appendingPathComponent("held-output", isDirectory: true)
        #expect(throws: ExportFileWriterError.unsafeParent) {
            _ = try parentWriter.writeIncrementally(
                fileName: "report.json",
                beforePublish: {
                    try FileManager.default.moveItem(at: parentFixture.output, to: heldOutput)
                    try FileManager.default.createDirectory(at: parentFixture.output, withIntermediateDirectories: false)
                }
            ) { sink in
                try sink(Data("safe".utf8))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parentFixture.output.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: heldOutput.path).contains { $0.hasSuffix(".part") } == false)

        let symlinkFixture = try FileFixture()
        defer { symlinkFixture.remove() }
        let symlinkWriter = try ExportFileWriter(outputRoot: symlinkFixture.output)
        let outside = symlinkFixture.root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let destination = symlinkFixture.output.appendingPathComponent("report.json")
        try Data("original".utf8).write(to: destination)
        #expect(throws: ExportFileWriterError.unsafeDestination) {
            _ = try symlinkWriter.writeIncrementally(
                fileName: "report.json",
                overwrite: .always,
                beforePublish: {
                    try FileManager.default.removeItem(at: destination)
                    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
                }
            ) { sink in
                try sink(Data("replacement".utf8))
            }
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "outside")

        let competitorFixture = try FileFixture()
        defer { competitorFixture.remove() }
        let competitorWriter = try ExportFileWriter(outputRoot: competitorFixture.output)
        let competitor = competitorFixture.output.appendingPathComponent("report.json")
        #expect(throws: ExportFileWriterError.destinationExists) {
            _ = try competitorWriter.writeIncrementally(
                fileName: "report.json",
                beforePublish: {
                    try Data("competitor".utf8).write(to: competitor)
                }
            ) { sink in
                try sink(Data("ours".utf8))
            }
        }
        #expect(try String(contentsOf: competitor, encoding: .utf8) == "competitor")
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

        let long = String(repeating: "界", count: 100)
        #expect(ExportPathComponent.safe(long).lengthOfBytes(using: .utf8) <= ExportPathComponent.maximumUTF8Bytes)
    }

    @Test
    func genericPerDocumentWriterUsesStableIdentityNamesAndExtensionValidation() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let bundle = FixtureFactory.bundleWithDuplicateTitles()

        let result = try writer.writeDocuments(bundle, fileExtension: "json") { group in
            Data("records=\(group.records.count)".utf8)
        }
        let expected = try bundle.groups.map { group in
            "Same-\(try #require(group.documentIdentity).fullKey).json"
        }
        #expect(result.documentFileCount == 2)
        #expect(result.files.map(\.lastPathComponent) == expected)
        #expect(Set(expected).count == 2)
        #expect(expected.allSatisfy { $0.utf8.count <= 200 })
        #expect(try result.files.map { try String(contentsOf: $0, encoding: .utf8) } == ["records=1", "records=1"])

        #expect(throws: ExportFileWriterError.invalidFileName) {
            _ = try writer.writeDocuments(bundle, fileExtension: "../json") { _ in Data() }
        }
    }

    @Test
    func documentFilenameIsStableAcrossOrderAndSubsetAndDoesNotLeakRawIdentity() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let rawA = "private/A #?% 文档/" + String(repeating: "x", count: 2_100)
        let rawB = "private/B #?% 文档/" + String(repeating: "y", count: 2_100)
        let a = FixtureFactory.group(pk: 1, assetID: rawA, title: String(repeating: "Same", count: 100))
        let b = FixtureFactory.group(pk: 2, assetID: rawB, title: String(repeating: "Same", count: 100))

        func names(_ groups: [ExportGroup]) throws -> [String: String] {
            var result: [String: String] = [:]
            _ = try writer.forEachDocument(FixtureFactory.makeBundle(groups: groups), fileExtension: "md") { group, fileName in
                result[try #require(group.documentIdentity).fullKey] = fileName
            }
            return result
        }

        let together = try names([a, b])
        let reversed = try names([b, a])
        let alone = try names([a])
        let aKey = try #require(a.documentIdentity).fullKey
        #expect(together == reversed)
        #expect(together[aKey] == alone[aKey])
        #expect(Set(together.values).count == 2)
        for fileName in together.values {
            #expect(fileName.utf8.count <= 200)
            #expect(fileName.contains("doc1_"))
            #expect(fileName.contains("private/") == false)
            #expect(fileName.contains("#") == false)
            #expect(fileName.contains("文档") == false)
        }
    }

    @Test
    func documentIdentityHashesExactUTF8IncrementallyAndStemTraversalIsBounded() throws {
        let raw = "A/#?%/e\u{301}/é/界"
        let key = ResolvedExportSourceKey.epubAsset(raw)
        var reference = Data("applebookscli.export.document.v1\0epub-asset\0".utf8)
        reference.append(contentsOf: raw.utf8)
        let expected = "doc1_" + SHA256.hash(data: reference).map { String(format: "%02x", $0) }.joined()
        #expect(try ExportDocumentIdentity.make(sourceKey: key).fullKey == expected)

        let hugeTitle = String(repeating: "Title ", count: (128 * 1_024 * 1_024 / 6) + 1)
        var stemPeak = 0
        let stem = ExportPathComponent.safe(hugeTitle, maximumUTF8Bytes: 120) {
            stemPeak = max(stemPeak, $0)
        }
        #expect(stem.utf8.count <= 120)
        #expect(stemPeak <= 120)

        let hugeIdentity = String(repeating: "z", count: 128 * 1_024 * 1_024 + 1)
        var digestPeak = 0
        let digest = try ExportDocumentIdentity.defaultDigest(for: .epubAsset(hugeIdentity)) {
            digestPeak = max(digestPeak, $0)
        }
        #expect(digest.count == 32)
        #expect(digestPeak <= 4_096)
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
    func symlinkOutputRootAndAncestorsAreRejectedWithoutFollowingThem() throws {
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

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: outsideDirectory.path)) == ["nested"])
    }

    @Test
    func countOnlyWritersMatchLegacyArtifactsWithoutReturningPaths() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let bundle = FixtureFactory.bundleWithDuplicateTitles()
        let legacy = try ExportFileWriter(outputRoot: fixture.output.appendingPathComponent("legacy"))
        let canonical = try ExportFileWriter(outputRoot: fixture.output.appendingPathComponent("canonical"))
        let result = try legacy.writeMarkdown(bundle, layout: .perDocument)
        let count = try canonical.writeDocumentsIncrementallyCount(bundle, fileExtension: "md") { group, sink in
            try MarkdownAnnotationExporter.stream(group, to: sink)
        }
        #expect(count == 2)
        #expect(result.documentFileCount == count)
        #expect(result.files.count == 2)
        for path in result.files {
            let relative = String(path.path.dropFirst(legacy.outputRoot.path.count + 1))
            #expect(try Data(contentsOf: path) == Data(contentsOf: canonical.outputRoot.appendingPathComponent(relative)))
        }
        let json = try canonical.writeDocumentsIncrementallyCount(bundle, fileExtension: "json") { _, sink in
            try sink(Data("{}".utf8))
        }
        #expect(json == count)
    }

    @Test
    func countOnlyDocumentTraversalKeepsScalarResultsForLargeExports() throws {
        let fixture = try FileFixture()
        defer { fixture.remove() }
        let writer = try ExportFileWriter(outputRoot: fixture.output)
        let groups = (0..<100_001).map { index in
            let assetID = "synthetic-\(index)"
            return ExportGroup(
                source: .epubUnmapped(assetID: assetID),
                records: [],
                documentIdentity: try! ExportDocumentIdentity.make(sourceKey: .epubAsset(assetID))
            )
        }
        let bundle = FixtureFactory.makeBundle(groups: groups)
        var materialized = 0
        let count = try writer.forEachDocument(bundle, fileExtension: "md") { _, fileName in
            #expect(fileName.hasPrefix("Unmapped%20EPUB-doc1_"))
            #expect(fileName.hasSuffix(".md"))
            #expect(fileName.utf8.count <= 200)
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
            for grouping in [ExportFileGrouping.single, .perDocument] {
                #expect(throws: ExportFileWriterError.destinationExists) {
                    try ExportFileWriter.validateDestination(target, grouping: grouping, overwrite: .never)
                }
            }
        }
        for (target, grouping) in [(file, ExportFileGrouping.perDocument), (directory, .single), (link, .single)] {
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

    private enum FixtureError: Error, Equatable {
        case stopped
    }

    private final class FileFixture {
        let root: URL
        let output: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
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
        static func bundle(
            title: String,
            author: String?,
            note: String = "note"
        ) -> ExportBundle {
            makeBundle(groups: [group(pk: 1, assetID: "asset-1", title: title, author: author, note: note)])
        }

        static func bundleWithDuplicateTitles() -> ExportBundle {
            makeBundle(groups: [
                group(pk: 1, assetID: "asset-1", title: "Same"),
                group(pk: 2, assetID: "asset-2", title: "Same"),
            ])
        }

        static func group(
            pk: Int64,
            assetID: String,
            title: String,
            author: String? = nil,
            note: String = "note"
        ) -> ExportGroup {
            let book = makeBook(pk: pk, assetID: assetID, title: title, author: author)
            return ExportGroup(
                source: .epubCurrent(book),
                records: [makeRecord(pk: pk, book: book, note: note)],
                documentIdentity: try! ExportDocumentIdentity.make(sourceKey: .epubAsset(assetID))
            )
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

        private static func makeBook(pk: Int64, assetID: String, title: String, author: String?) -> Book {
            Book(
                localPK: pk,
                assetID: assetID,
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

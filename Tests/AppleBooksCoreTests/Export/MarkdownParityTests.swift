import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("MarkdownParityTests")
struct MarkdownParityTests {
    @Test
    func bundleRendererPreservesFinalOrderAndContainsHostileTextInSafeContexts() throws {
        let fixture = try Fixture()
        let markdown = renderMarkdown(fixture.bundle)

        #expect(markdown.hasPrefix("# Apple Books export\n\n"))
        #expect(markdown.firstRange(of: "SECOND")!.lowerBound < markdown.firstRange(of: "FIRST")!.lowerBound)
        #expect(markdown.firstRange(of: "Hostile")!.lowerBound < markdown.firstRange(of: "PDF")!.lowerBound)
        #expect(markdown.contains("**Source:** EPUB"))
        #expect(markdown.contains("**Source:** PDF"))
        #expect(markdown.contains("**Page:** 7"))
        #expect(markdown.contains("**Created:** 2020-09-13T12:26:40.500Z"))
        #expect(markdown.contains("**Modified:** 2020-09-13T12:26:40.500Z"))
        #expect(markdown.contains("**Color:** purple"))
        #expect(markdown.contains("**Underline:** true"))

        let lines = markdown.components(separatedBy: "\n")
        #expect(lines.count { $0.hasPrefix("# ") } == 1)
        #expect(lines.count { $0.hasPrefix("## ") } == 2)
        #expect(lines.count { $0.hasPrefix("### ") } == 3)
        #expect(lines.contains("---") == false)
        #expect(lines.contains { $0.hasPrefix("```") } == false)
        #expect(markdown.contains("<script>") == false)
        #expect(markdown.contains("**Chapter:** Chapter 2"))
        #expect(markdown.contains("**Location:** 42"))
        #expect(markdown.contains("epubcfi") == false)
        #expect(markdown.contains("**Apple Books:** [Open book](<ibooks://assetid/"))
        #expect(markdown.contains(try #require(fixture.book.assetID)) == false)
        #expect(markdown.contains("/tmp/") == false)
        #expect(markdown.contains("]( <script>") == false)
        #expect(markdown.contains("](<script>") == false)
        #expect(markdown.contains("\\<script\\>"))
        #expect(markdown.contains("\\]\\("))
        #expect(markdown.contains("\\`\\`\\`"))
        #expect(markdown.contains(#"\*star\*"#))
        #expect(markdown.contains(#"\_under\_"#))
        #expect(markdown.contains(#"\{brace\}"#))
        #expect(markdown.contains(#"\+plus"#))
        #expect(markdown.contains(#"\!bang"#))
        #expect(markdown.contains(#"\|pipe"#))
        #expect(markdown.contains(#"\\slash"#))
        #expect(markdown.contains("> \\# SECOND"))
        #expect(markdown.contains("> ---"))

        // Presentation escaping must not rewrite canonical source values.
        #expect(fixture.book.title == fixture.hostileTitle)
        #expect(fixture.book.author == fixture.hostileAuthor)
        #expect(fixture.secondAnnotation.selectedText == fixture.hostileQuote)
        #expect(fixture.secondAnnotation.note == fixture.hostileNote)
        #expect(fixture.pdfSource.fileURL.path == fixture.hostilePath)
    }

    @Test
    func perDocumentRendererUsesSameGroupAndDoesNotResortRecords() throws {
        let fixture = try Fixture()
        let markdown = renderMarkdown(fixture.bundle.groups[0])

        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("# Apple Books export") == false)
        #expect(markdown.firstRange(of: "SECOND")!.lowerBound < markdown.firstRange(of: "FIRST")!.lowerBound)
        #expect(markdown.components(separatedBy: "\n").count { $0.hasPrefix("## ") } == 0)
        #expect(markdown.components(separatedBy: "\n").count { $0.hasPrefix("### ") } == 2)
    }

    @Test
    func whitespacePresenceUsesSharedSemanticsAndDoesNotEmitBlankQuotesOrNotes() throws {
        let annotation = Annotation(
            localPK: 1,
            uuid: nil,
            rawAssetID: "asset",
            isDeleted: false,
            isUnderline: false,
            style: 1,
            type: 1,
            createdAt: nil,
            modifiedAt: nil,
            representativeText: "representative fallback",
            selectedText: " \t\r\n",
            note: "\r\n\t ",
            location: nil,
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil
        )
        let epubRecord = ExportRecord(payload: .epub(.init(annotation: annotation, source: .unmapped)))
        let epub = renderMarkdown(
            ExportGroup(source: .epubUnmapped(assetID: "asset"), records: [epubRecord])
        )
        #expect(AnnotationContentSemantics.hasContent(annotation.selectedText) == false)
        #expect(epubRecord.hasHighlight == false)
        #expect(epubRecord.hasNote == false)
        #expect(epub.contains("> representative fallback"))
        #expect(epub.contains("**Note:**") == false)
        #expect(epub.contains(">  ") == false)

        let pdfSource = PDFSource(fileURL: URL(fileURLWithPath: "/synthetic/whitespace.pdf"), book: nil)
        let pdfRecord = ExportRecord(payload: .pdf(
            source: pdfSource,
            highlight: PDFHighlight(
                page: 1,
                traversalIndex: 0,
                bounds: .zero,
                quadrilateralPoints: [],
                note: " \t\r\n",
                pdfKitRGBA: nil,
                presentationColor: nil,
                modifiedAt: nil,
                text: "PDF quote",
                textSource: .boundsFallback,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
        ))
        let pdf = renderMarkdown(
            ExportGroup(source: .pdf(pdfSource), records: [pdfRecord])
        )
        #expect(pdfRecord.hasNote == false)
        #expect(pdf.contains("> PDF quote"))
        #expect(pdf.contains("**Note:**") == false)
    }

    @Test
    func streamingManyRecordsOver256MiBKeepsOnlyFixedSizeChunks() throws {
        let rawText = String(repeating: "m", count: 1_024 * 1_024)
        let records = (0..<257).map { index in
            let annotation = Annotation(
                localPK: Int64(index + 1),
                uuid: nil,
                rawAssetID: "large-asset",
                isDeleted: false,
                isUnderline: false,
                style: nil,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: rawText,
                note: nil,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            return ExportRecord(payload: .epub(.init(annotation: annotation, source: .unmapped)))
        }
        let group = ExportGroup(source: .epubUnmapped(assetID: "large-asset"), records: records)
        let bundle = ExportBundle(
            options: try ExportOptions(source: .epub),
            groups: [group],
            warnings: [],
            statistics: ExportStatistics(
                documentCount: 1,
                epubDocumentCount: 1,
                pdfDocumentCount: 0,
                recordCount: records.count,
                epubAnnotationCount: records.count,
                pdfHighlightCount: 0,
                highlightCount: records.count,
                noteCount: 0,
                historicalEPUBAnnotationCount: 0,
                unmappedEPUBAnnotationCount: records.count
            ),
            sourceTotals: ExportSourceTotals(
                epubDocumentCount: 1,
                epubAnnotationCount: records.count,
                pdfAttemptedDocumentCount: 0,
                pdfSucceededDocumentCount: 0,
                pdfFailedDocumentCount: 0,
                pdfHighlightCount: 0
            )
        )
        var totalBytes = 0
        var maximumChunk = 0
        var maximumBuffered = 0
        try MarkdownAnnotationExporter.stream(
            bundle,
            observeBufferedBytes: { maximumBuffered = max(maximumBuffered, $0) }
        ) { chunk in
            totalBytes += chunk.count
            maximumChunk = max(maximumChunk, chunk.count)
        }

        #expect(totalBytes > 256 * 1_024 * 1_024)
        #expect(maximumChunk <= ExportFileWriter.maximumChunkBytes)
        #expect(maximumBuffered <= ExportFileWriter.maximumChunkBytes)
    }

    @Test
    func emptyBundleAndEmptyDocumentHaveExplicitStates() throws {
        let options = try ExportOptions()
        let emptyBundle = ExportBundle(
            options: options,
            groups: [],
            warnings: [],
            statistics: ExportStatistics(
                documentCount: 0,
                epubDocumentCount: 0,
                pdfDocumentCount: 0,
                recordCount: 0,
                epubAnnotationCount: 0,
                pdfHighlightCount: 0,
                highlightCount: 0,
                noteCount: 0,
                historicalEPUBAnnotationCount: 0,
                unmappedEPUBAnnotationCount: 0
            ),
            sourceTotals: ExportSourceTotals(
                epubDocumentCount: 0,
                epubAnnotationCount: 0,
                pdfAttemptedDocumentCount: 0,
                pdfSucceededDocumentCount: 0,
                pdfFailedDocumentCount: 0,
                pdfHighlightCount: 0
            )
        )
        #expect(renderMarkdown(emptyBundle) == "# Apple Books export\n\n_No records._\n")

        let group = ExportGroup(source: .epubUnmapped(assetID: "missing"), records: [])
        let renderedGroup = renderMarkdown(group)
        #expect(renderedGroup.contains("# Unmapped EPUB"))
        #expect(renderedGroup.contains("**Identity:**") == false)
        #expect(renderedGroup.contains("_No records._"))
    }

    private struct Fixture {
        let hostileTitle = "# Hostile\n---\n``` title ]( <script>"
        let hostileAuthor = "Author ](\n<script>"
        let hostileQuote = "# SECOND *star* _under_ {brace} +plus !bang |pipe \\slash\n---\n``` quote ]( <script>"
        let hostileNote = "note\r---\r``` ]( <script>"
        let hostilePath = "/tmp/# PDF\n--- ]( <script>.pdf"
        let date = Date(timeIntervalSince1970: 1_600_000_000.5)
        let book: Book
        let secondAnnotation: Annotation
        let pdfSource: PDFSource
        let bundle: ExportBundle

        init() throws {
            book = Book(
                localPK: 1,
                assetID: "asset ]( <script>",
                title: hostileTitle,
                author: hostileAuthor,
                description: nil,
                epubID: nil,
                genre: nil,
                genresRaw: nil,
                comments: nil,
                language: nil,
                year: nil,
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
            secondAnnotation = Annotation(
                localPK: 2,
                uuid: nil,
                rawAssetID: book.assetID,
                isDeleted: false,
                isUnderline: true,
                style: 5,
                type: 1,
                createdAt: date,
                modifiedAt: date,
                representativeText: nil,
                selectedText: hostileQuote,
                note: hostileNote,
                location: Location(rawCFI: "epubcfi(/6/4[chapter]!/4/2,:3,:9) ]( <script>"),
                chapterHint: "Chapter 2",
                physicalLocation: 42,
                rangeStart: nil,
                rangeEnd: nil
            )
            let firstAnnotation = Annotation(
                localPK: 1,
                uuid: nil,
                rawAssetID: book.assetID,
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: nil,
                representativeText: nil,
                selectedText: "FIRST",
                note: nil,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            pdfSource = PDFSource(
                fileURL: URL(fileURLWithPath: hostilePath).standardizedFileURL,
                book: nil
            )
            let pdfHighlight = PDFHighlight(
                page: 7,
                traversalIndex: 1,
                bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
                quadrilateralPoints: [],
                note: "PDF note ]( <script>",
                pdfKitRGBA: [0.3, 0.2, 0.7, 1],
                presentationColor: PDFColorMatch(color: .purple, distance: 0.1, isApproximate: true),
                modifiedAt: date,
                text: "PDF quote ``` ]( <script>",
                textSource: .boundsFallback,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
            let groups = [
                ExportGroup(
                    source: .epubCurrent(book),
                    records: [
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(annotation: secondAnnotation, source: .currentLibrary(book))
                            )
                        ),
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(annotation: firstAnnotation, source: .currentLibrary(book))
                            )
                        ),
                    ]
                ),
                ExportGroup(
                    source: .pdf(pdfSource),
                    records: [ExportRecord(payload: .pdf(source: pdfSource, highlight: pdfHighlight))]
                ),
            ]
            bundle = ExportBundle(
                options: try ExportOptions(source: .all),
                groups: groups,
                warnings: [],
                statistics: ExportStatistics(
                    documentCount: 2,
                    epubDocumentCount: 1,
                    pdfDocumentCount: 1,
                    recordCount: 3,
                    epubAnnotationCount: 2,
                    pdfHighlightCount: 1,
                    highlightCount: 3,
                    noteCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: 0
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: 1,
                    epubAnnotationCount: 2,
                    pdfAttemptedDocumentCount: 1,
                    pdfSucceededDocumentCount: 1,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: 1
                )
            )
        }
    }
}

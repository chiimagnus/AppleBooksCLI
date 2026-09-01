import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("MarkdownParityTests")
struct MarkdownParityTests {
    @Test
    func bundleRendererPreservesFinalOrderAndContainsHostileTextInSafeContexts() throws {
        let fixture = try Fixture()
        let markdown = MarkdownAnnotationExporter.render(fixture.bundle)

        #expect(markdown.hasPrefix("# Apple Books export\n\n"))
        #expect(markdown.firstRange(of: "SECOND")!.lowerBound < markdown.firstRange(of: "FIRST")!.lowerBound)
        #expect(markdown.firstRange(of: "Hostile")!.lowerBound < markdown.firstRange(of: "PDF")!.lowerBound)
        #expect(markdown.contains("**Source:** EPUB"))
        #expect(markdown.contains("**Source:** PDF"))
        #expect(markdown.contains("**Page:** 7"))
        #expect(markdown.contains("**Date:** 2020-09-13T12:26:40.500Z"))
        #expect(markdown.contains("**Color:** purple"))
        #expect(markdown.contains("**Underline:** true"))

        let lines = markdown.components(separatedBy: "\n")
        #expect(lines.count { $0.hasPrefix("# ") } == 1)
        #expect(lines.count { $0.hasPrefix("## ") } == 2)
        #expect(lines.count { $0.hasPrefix("### ") } == 3)
        #expect(lines.contains("---") == false)
        #expect(lines.contains { $0.hasPrefix("```") } == false)
        #expect(markdown.contains("<script>") == false)
        #expect(markdown.contains("](") == false)
        #expect(markdown.contains("\\<script\\>"))
        #expect(markdown.contains("\\]\\("))
        #expect(markdown.contains("\\`\\`\\`"))
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
        let markdown = MarkdownAnnotationExporter.render(fixture.bundle.groups[0])

        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("# Apple Books export") == false)
        #expect(markdown.firstRange(of: "SECOND")!.lowerBound < markdown.firstRange(of: "FIRST")!.lowerBound)
        #expect(markdown.components(separatedBy: "\n").count { $0.hasPrefix("## ") } == 0)
        #expect(markdown.components(separatedBy: "\n").count { $0.hasPrefix("### ") } == 2)
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
                bookmarkCount: 0,
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
        #expect(MarkdownAnnotationExporter.render(emptyBundle) == "# Apple Books export\n\n_No records._\n")

        let group = ExportGroup(source: .epubUnmapped(assetID: "missing"), records: [])
        let renderedGroup = MarkdownAnnotationExporter.render(group)
        #expect(renderedGroup.contains("# Unmapped EPUB"))
        #expect(renderedGroup.contains("**Identity:** missing"))
        #expect(renderedGroup.contains("_No records._"))
    }

    private struct Fixture {
        let hostileTitle = "# Hostile\n---\n``` title ]( <script>"
        let hostileAuthor = "Author ](\n<script>"
        let hostileQuote = "# SECOND\n---\n``` quote ]( <script>"
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
                chapterHint: nil,
                physicalLocation: nil,
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
                options: try ExportOptions(source: .all, kinds: [.highlight, .note, .bookmark]),
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
                    bookmarkCount: 0,
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

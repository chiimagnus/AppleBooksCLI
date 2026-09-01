import CoreGraphics
import Foundation
import SwiftSoup
import Testing
@testable import AppleBooksCore

@Suite("HTMLInteractionTests")
struct HTMLInteractionTests {
    @Test
    func controlsAndGeneratedTokensMatchInteractionContract() throws {
        let html = try fixtureHTML()
        let document = try SwiftSoup.parse(html)

        #expect(try document.select("#export-search").size() == 1)
        #expect(try document.select("#collapse-all").size() == 1)
        #expect(try document.select("#expand-all").size() == 1)
        #expect(try document.select(".sidebar-toggle[aria-controls=document-sidebar]").size() == 1)
        #expect(try document.select(".book-section").size() == 2)
        #expect(try document.select(".book-toggle").size() == 2)
        #expect(try document.select(".book-body").size() == 2)

        let sections = try document.select(".book-section").array()
        #expect(try sections.map { try $0.attr("id") } == ["book-0", "book-1"])
        let links = try document.select(".sidebar-link").array()
        #expect(try links.map { try $0.attr("data-book-token") } == ["book-0", "book-1"])
        #expect(try links.map { try $0.attr("href") } == ["#book-0", "#book-1"])
        let toggles = try document.select(".book-toggle").array()
        #expect(try toggles.map { try $0.attr("aria-controls") } == ["book-body-0", "book-body-1"])
    }

    @Test
    func scriptUsesDOMTextAndNamespacedOrdinalStateWithoutEmbeddingUserValues() throws {
        let html = try fixtureHTML()
        let document = try SwiftSoup.parse(html)
        let script = try #require(document.select("script").first()?.data())

        #expect(script.contains("applebookscli.export.html.v1"))
        #expect(script.contains("localStorage.getItem(storageKey)"))
        #expect(script.contains("localStorage.setItem(storageKey"))
        #expect(script.contains("/^book-\\d+$/"))
        #expect(script.contains("section.textContent.toLowerCase().includes(query)"))
        #expect(script.contains("document.getElementById(\"collapse-all\")"))
        #expect(script.contains("document.getElementById(\"expand-all\")"))
        #expect(script.contains("IntersectionObserver"))
        #expect(script.contains("aria-current"))
        #expect(script.contains("matchMedia(\"(max-width: 720px)\")"))
        #expect(script.contains("sidebar.contains(event.target)"))

        for raw in [Fixture.assetID, Fixture.title, Fixture.author, Fixture.quote, Fixture.note] {
            #expect(script.contains(raw) == false)
        }
    }

    @Test
    func responsiveAndPrintRulesStaySelfContainedAndForcePrintableExpandedContent() throws {
        let html = try fixtureHTML()
        let document = try SwiftSoup.parse(html)
        let style = try #require(document.select("style").first()?.data())

        #expect(style.contains("@media (max-width: 720px)"))
        #expect(style.contains(".sidebar.is-open { display: block; }"))
        #expect(style.contains("@media print"))
        #expect(style.contains(".toolbar, .sidebar, .sidebar-toggle, .book-toggle { display: none !important; }"))
        #expect(style.contains(".book-section { display: block !important;"))
        #expect(style.contains(".book-body[hidden] { display: block !important; }"))

        let lowered = html.lowercased()
        #expect(lowered.contains("http://") == false)
        #expect(lowered.contains("https://") == false)
        #expect(lowered.contains("//fonts.") == false)
        #expect(lowered.contains("@import url") == false)
    }

    private func fixtureHTML() throws -> String {
        HTMLExporter.render(try Fixture().bundle)
    }

    private struct Fixture {
        static let assetID = "raw-asset-should-never-enter-script"
        static let title = "Searchable Title"
        static let author = "Searchable Author"
        static let quote = "Searchable Quote"
        static let note = "Searchable Note"

        let bundle: ExportBundle

        init() throws {
            let book = Book(
                localPK: 1,
                assetID: Self.assetID,
                title: Self.title,
                author: Self.author,
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
            let annotation = Annotation(
                localPK: 2,
                uuid: "annotation",
                rawAssetID: Self.assetID,
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: Self.quote,
                note: Self.note,
                location: Location(rawCFI: "epubcfi(/6/2[item]!/4/1:3)"),
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            let epub = ExportGroup(
                source: .epubCurrent(book),
                records: [ExportRecord(payload: .epub(EnrichedAnnotation(annotation: annotation, source: .currentLibrary(book))))]
            )

            let pdfSource = PDFSource(fileURL: URL(fileURLWithPath: "/tmp/searchable.pdf"), book: nil)
            let pdf = ExportGroup(
                source: .pdf(pdfSource),
                records: [
                    ExportRecord(payload: .pdf(
                        source: pdfSource,
                        highlight: PDFHighlight(
                            page: 1,
                            traversalIndex: 0,
                            bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
                            quadrilateralPoints: [],
                            note: nil,
                            pdfKitRGBA: nil,
                            presentationColor: nil,
                            modifiedAt: nil,
                            text: "PDF searchable text",
                            textSource: .boundsFallback,
                            textIsApproximate: true,
                            textUnavailableReason: nil
                        )
                    ))
                ]
            )

            bundle = ExportBundle(
                options: try ExportOptions(source: .all),
                groups: [epub, pdf],
                warnings: [],
                statistics: ExportStatistics(
                    documentCount: 2,
                    epubDocumentCount: 1,
                    pdfDocumentCount: 1,
                    recordCount: 2,
                    epubAnnotationCount: 1,
                    pdfHighlightCount: 1,
                    highlightCount: 2,
                    noteCount: 0,
                    bookmarkCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: 0
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: 1,
                    epubAnnotationCount: 1,
                    pdfAttemptedDocumentCount: 1,
                    pdfSucceededDocumentCount: 1,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: 1
                )
            )
        }
    }
}

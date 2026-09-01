import CoreGraphics
import Foundation
import SwiftSoup
import Testing
@testable import AppleBooksCore

@Suite("HTMLExporterStructureTests")
struct HTMLExporterStructureTests {
    @Test
    func emptyBundleStillProducesSelfContainedSemanticShell() throws {
        let html = HTMLExporter.render(try emptyBundle())
        let document = try SwiftSoup.parse(html)

        #expect(try document.select("header.page-header").array().count == 1)
        #expect(try document.select("aside.sidebar").array().count == 1)
        #expect(try document.select("main.content").array().count == 1)
        #expect(try document.select("section.book-section").array().isEmpty)
        #expect(try document.select("p.empty-state").first()?.text() == "No records.")
        try assertNoExternalDependencies(html: html, document: document)
    }

    @Test
    func oneDocumentUsesGeneratedOrdinalForNavigationAndNeverRawIdentity() throws {
        let fixture = try Fixture(groupCount: 1)
        let html = HTMLExporter.render(fixture.bundle)
        let document = try SwiftSoup.parse(html)
        let links = try document.select("aside.sidebar a").array()
        let sections = try document.select("section.book-section").array()

        #expect(links.count == 1)
        #expect(sections.count == 1)
        #expect(try links[0].attr("href") == "#book-0")
        #expect(try sections[0].attr("id") == "book-0")
        #expect(try links[0].attr("href").contains(fixture.hostileAssetID) == false)
        #expect(try sections[0].attr("id").contains(fixture.hostileAssetID) == false)
        #expect(try document.body()?.text().contains(fixture.hostileAssetID) == true)
        try assertNoExternalDependencies(html: html, document: document)
    }

    @Test
    func hostileUserContentRemainsTextAndManyGroupsPreserveBundleOrder() throws {
        let fixture = try Fixture(groupCount: 3)
        let html = HTMLExporter.render(fixture.bundle)
        let document = try SwiftSoup.parse(html)
        let sections = try document.select("section.book-section").array()
        let links = try document.select("aside.sidebar a").array()
        let headings = try document.select("section.book-section > header > h2").array()

        #expect(sections.count == 3)
        #expect(links.count == 3)
        #expect(headings.count == 3)
        for index in sections.indices {
            #expect(try sections[index].attr("id") == "book-\(index)")
            #expect(try links[index].attr("href") == "#book-\(index)")
        }
        #expect(try headings[0].text().contains("Current 中文") == true)
        #expect(try headings[1].text() == "Unmapped EPUB")
        #expect(try headings[2].text() == fixture.pdfSource.displayTitle)

        let scripts = try document.select("script").array()
        #expect(scripts.count == 1)
        let script = try #require(scripts.first?.data())
        for raw in [fixture.hostileTitle, fixture.hostileAssetID, fixture.hostileQuote, fixture.hostileNote, fixture.hostilePath] {
            #expect(script.contains(raw) == false)
        }
        #expect(try document.select("img").array().isEmpty)
        #expect(try document.select("[onerror]").array().isEmpty)
        #expect(try document.select("[onclick]").array().isEmpty)
        let bodyText = try #require(document.body()).text()
        #expect(bodyText.contains("</script>") == true)
        #expect(bodyText.contains("<img src=x onerror=alert(2)>") == true)
        #expect(bodyText.contains("quotes \" & < > 中文") == true)
        #expect(bodyText.contains(fixture.hostileAssetID) == true)
        #expect(bodyText.contains(fixture.hostilePath) == true)
        #expect(bodyText.contains("Page: 9"))
        #expect(bodyText.contains("Color: purple"))
        #expect(bodyText.contains("Underline: true"))
        #expect(bodyText.contains("2020-09-13T12:26:40.500Z"))

        // Raw user strings never become element IDs or navigation targets. Later interaction controls use
        // fixed renderer-owned IDs, while document identity stays ordinal-only.
        let idValues = try document.select("[id]").array().map { try $0.attr("id") }
        let sectionIDs = try sections.map { try $0.attr("id") }
        let bodyIDs = try document.select(".book-body[id]").array().map { try $0.attr("id") }
        let hrefValues = try document.select("a[href]").array().map { try $0.attr("href") }
        #expect(sectionIDs == ["book-0", "book-1", "book-2"])
        #expect(bodyIDs == ["book-body-0", "book-body-1", "book-body-2"])
        #expect(hrefValues == ["#book-0", "#book-1", "#book-2"])
        #expect(idValues.allSatisfy { $0.contains("asset") == false })
        #expect(hrefValues.allSatisfy { $0.contains("asset") == false })

        // Escaping is presentation-only; the canonical DTO stays byte-for-byte unchanged.
        #expect(fixture.currentBook.title == fixture.hostileTitle)
        #expect(fixture.currentBook.assetID == fixture.hostileAssetID)
        #expect(fixture.currentAnnotation.selectedText == fixture.hostileQuote)
        #expect(fixture.currentAnnotation.note == fixture.hostileNote)
        #expect(fixture.pdfSource.fileURL.path == fixture.hostilePath)

        try assertNoExternalDependencies(html: html, document: document)
    }

    private func assertNoExternalDependencies(html: String, document: Document) throws {
        #expect(html.contains("http://") == false)
        #expect(html.contains("https://") == false)
        #expect(html.contains("//fonts.") == false)
        #expect(html.lowercased().contains("@import url") == false)
        #expect(try document.select("script[src]").array().isEmpty)
        #expect(try document.select("link[href]").array().isEmpty)
        #expect(try document.select("img[src]").array().isEmpty)
    }

    private func emptyBundle() throws -> ExportBundle {
        ExportBundle(
            options: try ExportOptions(source: .all),
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
    }

    private struct Fixture {
        let hostileAssetID = "asset\" onclick=\"alert(1) <script>"
        let hostileTitle = "Current 中文 </script><img src=x onerror=alert(2)> quotes \" & < > 中文"
        let hostileQuote = "Quote </script><img src=x onerror=alert(2)> quotes \" & < > 中文"
        let hostileNote = "Note </script><img src=x onerror=alert(2)> quotes \" & < > 中文"
        let hostilePath = "/tmp/PDF </script><img src=x onerror=alert(2)> & \".pdf"
        let date = Date(timeIntervalSince1970: 1_600_000_000.5)
        let currentBook: Book
        let currentAnnotation: Annotation
        let pdfSource: PDFSource
        let bundle: ExportBundle

        init(groupCount: Int) throws {
            currentBook = Book(
                localPK: 1,
                assetID: hostileAssetID,
                title: hostileTitle,
                author: "Author </script> & <b>中文</b>",
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
            currentAnnotation = Annotation(
                localPK: 2,
                uuid: nil,
                rawAssetID: hostileAssetID,
                isDeleted: false,
                isUnderline: true,
                style: 5,
                type: 1,
                createdAt: nil,
                modifiedAt: date,
                representativeText: nil,
                selectedText: hostileQuote,
                note: hostileNote,
                location: Location(rawCFI: "epubcfi(/6/4)!/4/2 </script> & < >"),
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            pdfSource = PDFSource(fileURL: URL(fileURLWithPath: hostilePath).standardizedFileURL, book: nil)
            let pdfHighlight = PDFHighlight(
                page: 9,
                traversalIndex: 4,
                bounds: CGRect(x: 1, y: 2, width: 3, height: 4),
                quadrilateralPoints: [],
                note: hostileNote,
                pdfKitRGBA: [0.4, 0.2, 0.8, 1],
                presentationColor: PDFColorMatch(color: .purple, distance: 0.2, isApproximate: true),
                modifiedAt: date,
                text: hostileQuote,
                textSource: .quadSelection,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
            let allGroups = [
                ExportGroup(
                    source: .epubCurrent(currentBook),
                    records: [
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(annotation: currentAnnotation, source: .currentLibrary(currentBook))
                            )
                        ),
                    ]
                ),
                ExportGroup(
                    source: .epubUnmapped(assetID: "orphan <script> & 中文"),
                    records: [
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(
                                    annotation: Annotation(
                                        localPK: 3,
                                        uuid: nil,
                                        rawAssetID: "orphan <script> & 中文",
                                        isDeleted: false,
                                        isUnderline: false,
                                        style: 1,
                                        type: 1,
                                        createdAt: date,
                                        modifiedAt: nil,
                                        representativeText: nil,
                                        selectedText: "Orphan 中文",
                                        note: nil,
                                        location: nil,
                                        chapterHint: nil,
                                        physicalLocation: nil,
                                        rangeStart: nil,
                                        rangeEnd: nil
                                    ),
                                    source: .unmapped
                                )
                            )
                        ),
                    ]
                ),
                ExportGroup(
                    source: .pdf(pdfSource),
                    records: [ExportRecord(payload: .pdf(source: pdfSource, highlight: pdfHighlight))]
                ),
            ]
            let groups = Array(allGroups.prefix(groupCount))
            let epubCount = groups.count { group in
                switch group.source {
                case .epubCurrent, .epubHistorical, .epubUnmapped: true
                case .pdf: false
                }
            }
            let pdfCount = groups.count - epubCount
            let recordCount = groups.reduce(0) { $0 + $1.records.count }
            bundle = ExportBundle(
                options: try ExportOptions(source: .all, kinds: [.highlight, .note, .bookmark]),
                groups: groups,
                warnings: [],
                statistics: ExportStatistics(
                    documentCount: groups.count,
                    epubDocumentCount: epubCount,
                    pdfDocumentCount: pdfCount,
                    recordCount: recordCount,
                    epubAnnotationCount: epubCount,
                    pdfHighlightCount: pdfCount,
                    highlightCount: recordCount,
                    noteCount: 0,
                    bookmarkCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: groups.count > 1 ? 1 : 0
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: epubCount,
                    epubAnnotationCount: epubCount,
                    pdfAttemptedDocumentCount: pdfCount,
                    pdfSucceededDocumentCount: pdfCount,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: pdfCount
                )
            )
        }
    }
}

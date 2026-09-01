import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ExportOptionsTests")
struct ExportOptionsTests {
    @Test
    func canonicalDefaultsAreLowIOAndInvalidOptionsFailBeforeUse() throws {
        let options = try ExportOptions()
        #expect(options.source == .epub)
        #expect(options.bookSelectors.isEmpty)
        #expect(options.kinds == [.highlight, .note])
        #expect(options.colors == nil)
        #expect(options.underline == nil)
        #expect(options.order == .source)
        #expect(options.skipFirstPerBook == 0)
        #expect(options.grouping == .single)
        #expect(options.includeEPUBMetadata == false)
        #expect(options.cover == .none)

        #expect(throws: ExportOptionsError.emptyKinds) {
            _ = try ExportOptions(kinds: [])
        }
        #expect(throws: ExportOptionsError.emptyColors) {
            _ = try ExportOptions(colors: [])
        }
        #expect(throws: ExportOptionsError.negativeSkip) {
            _ = try ExportOptions(skipFirstPerBook: -1)
        }
        #expect(throws: ExportOptionsError.invalidBookSelector) {
            _ = try ExportOptions(bookSelectors: [.assetID("")])
        }
        #expect(throws: ExportOptionsError.invalidBookSelector) {
            _ = try ExportOptions(bookSelectors: [.pdfFile(URL(string: "https://example.invalid/book.pdf")!)])
        }
        #expect(throws: ExportOptionsError.invalidBookSelector) {
            _ = try ExportOptions(bookSelectors: [.pdfFile(URL(fileURLWithPath: "/tmp/one/../book.pdf"))])
        }
        #expect(throws: ExportOptionsError.conflictingOptions) {
            _ = try ExportOptions(
                source: .epub,
                bookSelectors: [.pdfFile(URL(fileURLWithPath: "/tmp/book.pdf"))]
            )
        }
        #expect(throws: ExportOptionsError.conflictingOptions) {
            _ = try ExportOptions(source: .pdf, includeEPUBMetadata: true)
        }
        #expect(throws: ExportOptionsError.conflictingOptions) {
            _ = try ExportOptions(source: .pdf, cover: .inline)
        }
    }

    @Test
    func presentationKindsAreDerivedWithoutMutatingCanonicalAnnotationFields() throws {
        let note = annotation(
            pk: 1,
            assetID: "asset",
            uuid: "uuid-note",
            selectedText: "quote",
            note: "  note  ",
            style: 4,
            underline: true,
            type: 9
        )
        let highlight = annotation(pk: 2, assetID: "asset", selectedText: "quote", note: nil, type: 8)
        let bookmark = annotation(pk: 3, assetID: "asset", selectedText: "", note: "  ", type: 7)
        let records = [note, highlight, bookmark].map { ExportRecord(payload: .epub(.init(annotation: $0, source: .unmapped))) }

        #expect(records.map(\.presentationKind) == [.note, .highlight, .bookmark])
        #expect(records[0].presentationColor == .pink)
        #expect(records[0].isUnderline)

        guard case let .epub(roundTripped) = records[0].payload else {
            Issue.record("expected EPUB record")
            return
        }
        #expect(roundTripped.annotation == note)
        #expect(roundTripped.annotation.uuid == "uuid-note")
        #expect(roundTripped.annotation.style == 4)
        #expect(roundTripped.annotation.type == 9)
        #expect(roundTripped.annotation.isUnderline == true)
        #expect(roundTripped.annotation.note == "  note  ")
    }

    @Test
    func knownCurrentPDFAEAnnotationIsExcludedButHistoricalAndUnmappedRowsAreNotGuessed() throws {
        let pdfBook = book(localPK: 10, assetID: "pdf-asset", contentType: 3)
        let currentPDFRow = ExportRecord(payload: .epub(.init(
            annotation: annotation(pk: 1, assetID: "pdf-asset", selectedText: "db row"),
            source: .currentLibrary(pdfBook)
        )))
        let historical = ExportRecord(payload: .epub(.init(
            annotation: annotation(pk: 2, assetID: "historical", selectedText: "historical row"),
            source: .historicalInferred(.init(title: "History", author: "Author"))
        )))
        let unmapped = ExportRecord(payload: .epub(.init(
            annotation: annotation(pk: 3, assetID: "unmapped", selectedText: "unmapped row"),
            source: .unmapped
        )))
        let pdfSource = source(path: "/synthetic/current.pdf", book: pdfBook)
        let pdfHighlight = ExportRecord(payload: .pdf(
            source: pdfSource,
            highlight: highlight(page: 1, traversal: 0, text: "pdf truth")
        ))

        let all = ExportSelection.apply(
            options: try ExportOptions(source: .all, kinds: [.highlight]),
            to: [currentPDFRow, historical, unmapped, pdfHighlight]
        )
        #expect(all == [historical, unmapped, pdfHighlight])

        let epub = ExportSelection.apply(
            options: try ExportOptions(source: .epub, kinds: [.highlight]),
            to: [currentPDFRow, historical, unmapped, pdfHighlight]
        )
        #expect(epub == [historical, unmapped])
    }

    @Test
    func colorUnderlineAndSelectorsFilterPresentationWithoutRewritingRawFields() throws {
        let underlined = ExportRecord(payload: .epub(.init(
            annotation: annotation(pk: 1, assetID: "asset-a", selectedText: "one", style: 0, underline: true),
            source: .unmapped
        )))
        let styleOnly = ExportRecord(payload: .epub(.init(
            annotation: annotation(pk: 2, assetID: "asset-a", selectedText: "two", style: 1, underline: false),
            source: .unmapped
        )))
        let pdfURL = URL(fileURLWithPath: "/synthetic/pdf-a.pdf").standardizedFileURL
        let pdf = ExportRecord(payload: .pdf(
            source: PDFSource(fileURL: pdfURL, book: book(localPK: 2, assetID: "pdf-a", contentType: 3)),
            highlight: highlight(page: 1, traversal: 0, color: .yellow)
        ))

        let underlineOnly = ExportSelection.apply(
            options: try ExportOptions(source: .all, kinds: [.highlight], underline: true),
            to: [underlined, styleOnly, pdf]
        )
        #expect(underlineOnly == [underlined])

        let green = ExportSelection.apply(
            options: try ExportOptions(source: .all, kinds: [.highlight], colors: [.green]),
            to: [underlined, styleOnly, pdf]
        )
        #expect(green == [styleOnly])

        let yellowPDF = ExportSelection.apply(
            options: try ExportOptions(
                source: .pdf,
                bookSelectors: [.pdfFile(pdfURL)],
                kinds: [.highlight],
                colors: [.yellow]
            ),
            to: [underlined, styleOnly, pdf]
        )
        #expect(yellowPDF == [pdf])

        let assetSelected = ExportSelection.apply(
            options: try ExportOptions(
                source: .all,
                bookSelectors: [.assetID("asset-a")],
                kinds: [.highlight]
            ),
            to: [underlined, styleOnly, pdf]
        )
        #expect(assetSelected == [underlined, styleOnly])
    }

    @Test
    func epubReadingOrderUsesNumericCFIValidFirstAndStableTies() throws {
        let records = [
            epubRecord(pk: 1, cfi: "not-a-cfi"),
            epubRecord(pk: 2, cfi: "epubcfi(/6/10[assertion999]!/4/2:1)"),
            epubRecord(pk: 3, cfi: "epubcfi(/6/2[ignore777]!/4/2:1)"),
            epubRecord(pk: 4, cfi: nil),
            epubRecord(pk: 5, cfi: "epubcfi(/6/2[different888]!/4/2:1)"),
            epubRecord(pk: 6, cfi: "epubcfi(/6/2[broken!/4/2:1)"),
        ]

        let ordered = ExportSelection.apply(
            options: try ExportOptions(kinds: [.highlight], order: .reading),
            to: records
        )
        #expect(ordered.compactMap(\.epubPK) == [3, 5, 2, 1, 4, 6])
    }

    @Test
    func pdfReadingOrderUsesPageThenTopToBottomThenLeftThenTraversal() throws {
        let pdfSource = source(path: "/synthetic/order.pdf")
        let records = [
            pdfRecord(source: pdfSource, page: 2, traversal: 0, x: 0, y: 90),
            pdfRecord(source: pdfSource, page: 1, traversal: 4, x: 20, y: 50),
            pdfRecord(source: pdfSource, page: 1, traversal: 3, x: 10, y: 50),
            pdfRecord(source: pdfSource, page: 1, traversal: 2, x: 10, y: 80),
            pdfRecord(source: pdfSource, page: 1, traversal: 1, x: 10, y: 50),
        ]

        let ordered = ExportSelection.apply(
            options: try ExportOptions(source: .pdf, kinds: [.highlight], order: .reading),
            to: records
        )
        #expect(ordered.compactMap(\.pdfTraversal) == [2, 1, 3, 4, 0])
    }

    @Test
    func skipFirstPerBookRunsAfterKindFilterAndFinalOrderingForEveryAnnotationRow() throws {
        let a = [
            epubRecord(pk: 1, assetID: "a", selected: "highlight-a1", note: nil, cfi: "epubcfi(/6/8)"),
            epubRecord(pk: 2, assetID: "a", selected: "highlight-a2", note: nil, cfi: "epubcfi(/6/2)"),
            epubRecord(pk: 3, assetID: "a", selected: "quote", note: "note-a", cfi: "epubcfi(/6/1)"),
        ]
        let b = [
            epubRecord(pk: 4, assetID: "b", selected: "highlight-b1", note: nil, cfi: "epubcfi(/6/4)"),
            epubRecord(pk: 5, assetID: "b", selected: "highlight-b2", note: nil, cfi: "epubcfi(/6/3)"),
        ]

        let ordered = ExportSelection.apply(
            options: try ExportOptions(
                kinds: [.highlight],
                order: .reading,
                skipFirstPerBook: 1
            ),
            to: a + b
        )
        #expect(ordered.compactMap(\.epubPK) == [1, 4])

        let sourceOrdered = ExportSelection.apply(
            options: try ExportOptions(kinds: [.highlight], skipFirstPerBook: 1),
            to: a + b
        )
        #expect(sourceOrdered.compactMap(\.epubPK) == [2, 5])
    }

    private func epubRecord(
        pk: Int64,
        assetID: String = "asset",
        selected: String? = "quote",
        note: String? = nil,
        cfi: String?
    ) -> ExportRecord {
        ExportRecord(payload: .epub(.init(
            annotation: annotation(
                pk: pk,
                assetID: assetID,
                selectedText: selected,
                note: note,
                cfi: cfi
            ),
            source: .unmapped
        )))
    }

    private func pdfRecord(
        source: PDFSource,
        page: Int,
        traversal: Int,
        x: Double,
        y: Double
    ) -> ExportRecord {
        ExportRecord(payload: .pdf(
            source: source,
            highlight: PDFHighlight(
                page: page,
                traversalIndex: traversal,
                bounds: CGRect(x: x, y: y, width: 20, height: 10),
                quadrilateralPoints: [],
                note: nil,
                pdfKitRGBA: nil,
                modifiedAt: nil,
                text: "pdf",
                textSource: .boundsFallback,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
        ))
    }

    private func source(path: String, book: Book? = nil) -> PDFSource {
        PDFSource(fileURL: URL(fileURLWithPath: path).standardizedFileURL, book: book)
    }

    private func highlight(
        page: Int,
        traversal: Int,
        text: String? = nil,
        color: PDFPresentationColor? = nil
    ) -> PDFHighlight {
        PDFHighlight(
            page: page,
            traversalIndex: traversal,
            bounds: CGRect(x: 0, y: 0, width: 10, height: 10),
            quadrilateralPoints: [],
            note: nil,
            pdfKitRGBA: color == nil ? nil : [1, 1, 0, 1],
            presentationColor: color.map { PDFColorMatch(color: $0, distance: 0, isApproximate: true) },
            modifiedAt: nil,
            text: text,
            textSource: text == nil ? nil : .boundsFallback,
            textIsApproximate: true,
            textUnavailableReason: text == nil ? .noTextSelection : nil
        )
    }

    private func annotation(
        pk: Int64,
        assetID: String?,
        uuid: String? = nil,
        selectedText: String? = nil,
        note: String? = nil,
        style: Int64? = nil,
        underline: Bool? = nil,
        type: Int64? = 1,
        cfi: String? = nil
    ) -> Annotation {
        Annotation(
            localPK: pk,
            uuid: uuid,
            rawAssetID: assetID,
            isDeleted: false,
            isUnderline: underline,
            style: style,
            type: type,
            createdAt: nil,
            modifiedAt: nil,
            representativeText: nil,
            selectedText: selectedText,
            note: note,
            location: cfi.map(Location.init(rawCFI:)),
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil
        )
    }

    private func book(localPK: Int64, assetID: String?, contentType: Int64?) -> Book {
        Book(
            localPK: localPK,
            assetID: assetID,
            title: nil,
            author: nil,
            description: nil,
            epubID: nil,
            genre: nil,
            genresRaw: nil,
            comments: nil,
            language: nil,
            year: nil,
            contentType: contentType,
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
}

private extension ExportRecord {
    var epubPK: Int64? {
        guard case let .epub(enriched) = payload else { return nil }
        return enriched.annotation.localPK
    }

    var pdfTraversal: Int? {
        guard case let .pdf(_, highlight) = payload else { return nil }
        return highlight.traversalIndex
    }
}

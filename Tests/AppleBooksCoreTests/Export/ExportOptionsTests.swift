import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ExportOptionsTests")
struct ExportOptionsTests {
    @Test
    func canonicalDefaultsAndInvalidOptionsFailBeforeUse() throws {
        let options = try ExportOptions()
        #expect(options.bookSelectors.isEmpty)
        #expect(options.hasHighlight == nil)
        #expect(options.hasNote == nil)
        #expect(options.colors == nil)
        #expect(options.underline == nil)
        #expect(options.grouping == .single)
        #expect(throws: ExportOptionsError.emptyColors) { _ = try ExportOptions(colors: []) }
        #expect(throws: ExportOptionsError.invalidBookSelector) {
            _ = try ExportOptions(bookSelectors: [.assetID("")])
        }
    }

    @Test
    func presenceDoesNotMutateRawAnnotation() throws {
        let note = annotation(pk: 1, assetID: "asset", uuid: "uuid-note", selectedText: "quote",
                              note: "  note  ", style: 4, underline: true, type: 9)
        let rows = [note, annotation(pk: 2, assetID: "asset", selectedText: "quote"),
                    annotation(pk: 3, assetID: "asset", selectedText: "", note: "  ")]
        let records = rows.map { ExportRecord(annotation: .init(annotation: $0, source: .unmapped)) }
        #expect(records.map(\.hasHighlight) == [true, true, false])
        #expect(records.map(\.hasNote) == [true, false, false])
        #expect(records[0].presentationColor == .pink)
        #expect(records[0].isUnderline)
        #expect(records[0].annotation.annotation == note)
    }

    @Test
    func optionalPresenceFiltersComposeForEPUB() throws {
        let rows: [(String?, String?, Bool?)] = [
            ("quote", nil, true), (nil, "note", false), ("quote", "note", nil),
            (" \t\r\n", "\r\n\t ", nil), (nil, nil, false), ("\u{00a0}", nil, false)
        ]
        let records = rows.enumerated().map { index, row in
            ExportRecord(annotation: .init(
                annotation: annotation(pk: Int64(index + 1), assetID: "matrix", selectedText: row.0,
                                       note: row.1, underline: row.2), source: .unmapped
            ))
        }
        let expectedHighlight = [true, false, true, false, false, true]
        let expectedNote = [false, true, true, false, false, false]
        let expectedUnderline = [true, false, false, false, false, false]
        let choices: [Bool?] = [nil, false, true]
        for hasHighlight in choices {
            for hasNote in choices {
                for underline in choices {
                    let selected = try ExportSelection.apply(options: try ExportOptions(
                        hasHighlight: hasHighlight, hasNote: hasNote, underline: underline
                    ), to: records)
                    let expected = records.indices.filter { index in
                        (expectedHighlight[index] || expectedNote[index])
                            && (hasHighlight == nil || hasHighlight == expectedHighlight[index])
                            && (hasNote == nil || hasNote == expectedNote[index])
                            && (underline == nil || underline == expectedUnderline[index])
                    }.map { records[$0] }
                    #expect(selected == expected)
                }
            }
        }
        let representativeOnly = ExportRecord(annotation: .init(
            annotation: annotation(pk: 20, assetID: "matrix", representativeText: "not a highlight"),
            source: .unmapped
        ))
        #expect(!representativeOnly.hasHighlight)
        #expect(try ExportSelection.apply(options: ExportOptions(), to: [representativeOnly]).isEmpty)
    }

    @Test
    func rawAssetIdentityIndependentOfPresentationSourceAndNilUsesUnknown() throws {
        let raw = "same/#?%/é"
        let value = annotation(pk: 1, assetID: raw, selectedText: "quote")
        let current = book(localPK: 1, assetID: raw, contentType: 1)
        let records = [
            ExportRecord(annotation: .init(annotation: value, source: .currentLibrary(current))),
            ExportRecord(annotation: .init(annotation: value, source: .historicalInferred(.init(title: "History", author: "Author")))),
            ExportRecord(annotation: .init(annotation: value, source: .unmapped)),
        ]
        #expect(records.map(\.documentSourceKey) == [.epubAsset(raw), .epubAsset(raw), .epubAsset(raw)])
        let unknownA = ExportRecord(annotation: .init(annotation: annotation(pk: 2, assetID: nil, selectedText: "a"), source: .unmapped))
        let unknownB = ExportRecord(annotation: .init(annotation: annotation(pk: 3, assetID: nil, selectedText: "b"), source: .unmapped))
        #expect(unknownA.documentSourceKey == .epubUnknown)
        #expect(unknownB.documentSourceKey == .epubUnknown)
    }

    @Test
    func currentPDFDatabaseRowIsExcludedButHistoricalAndUnmappedRowsRemain() throws {
        let pdfBook = book(localPK: 10, assetID: "pdf-asset", contentType: 3)
        let current = ExportRecord(annotation: .init(annotation: annotation(pk: 1, assetID: "pdf-asset", selectedText: "db row"), source: .currentLibrary(pdfBook)))
        let historical = ExportRecord(annotation: .init(annotation: annotation(pk: 2, assetID: "history", selectedText: "history"), source: .historicalInferred(.init(title: "History", author: "Author"))))
        let unmapped = ExportRecord(annotation: .init(annotation: annotation(pk: 3, assetID: "unmapped", selectedText: "unknown"), source: .unmapped))
        #expect(!current.isCurrentEPUBSource)
        #expect(try ExportSelection.apply(options: ExportOptions(hasHighlight: true), to: [current, historical, unmapped]) == [historical, unmapped])
    }

    @Test
    func colorAndUnderlineFilterPresentationWithoutRewritingRawFields() throws {
        let underlined = ExportRecord(annotation: .init(annotation: annotation(pk: 1, assetID: "asset", selectedText: "one", style: 0, underline: true), source: .unmapped))
        let styleOnly = ExportRecord(annotation: .init(annotation: annotation(pk: 2, assetID: "asset", selectedText: "two", style: 1, underline: false), source: .unmapped))
        #expect(try ExportSelection.apply(options: ExportOptions(hasHighlight: true, underline: true), to: [underlined, styleOnly]) == [underlined])
        #expect(try ExportSelection.apply(options: ExportOptions(hasHighlight: true, colors: [.green]), to: [underlined, styleOnly]) == [styleOnly])
        #expect(underlined.annotation.annotation.isUnderline == true)
        #expect(styleOnly.annotation.annotation.style == 1)
    }

    @Test
    func numericCFIReadingOrderKeepsValidFirstAndStableTies() throws {
        let oversizedCFI = "epubcfi(/6/2[" + String(repeating: "x", count: CFIResourcePolicy.maximumStructuralBytes) + "]!/4/2:1)"
        let records = [
            epubRecord(pk: 1, cfi: "not-a-cfi"),
            epubRecord(pk: 2, cfi: "epubcfi(/6/10[assertion999]!/4/2:1)"),
            epubRecord(pk: 3, cfi: "epubcfi(/6/2[ignore777]!/4/2:1)"),
            epubRecord(pk: 4, cfi: nil),
            epubRecord(pk: 5, cfi: "epubcfi(/6/2[different888]!/4/2:1)"),
            epubRecord(pk: 6, cfi: "epubcfi(/6/2[broken!/4/2:1)"),
            epubRecord(pk: 7, cfi: oversizedCFI)
        ]
        let ordered = try ExportSelection.apply(options: ExportOptions(hasHighlight: true), to: records)
        #expect(ordered.map { $0.annotation.annotation.localPK } == [3, 5, 2, 1, 4, 6, 7])
    }

    @Test
    func everyDocumentKeepsItsFirstRecordInReadingOrder() throws {
        let records = [
            epubRecord(pk: 1, assetID: "a", cfi: "epubcfi(/6/8)"),
            epubRecord(pk: 2, assetID: "a", cfi: "epubcfi(/6/2)"),
            epubRecord(pk: 3, assetID: "a", cfi: "epubcfi(/6/1)"),
            epubRecord(pk: 4, assetID: "b", cfi: "epubcfi(/6/4)"),
            epubRecord(pk: 5, assetID: "b", cfi: "epubcfi(/6/3)")
        ]
        let ordered = try ExportSelection.apply(options: ExportOptions(hasHighlight: true), to: records)
        #expect(ordered.map { $0.annotation.annotation.localPK } == [3, 2, 1, 5, 4])
    }

    private func epubRecord(pk: Int64, assetID: String = "asset", cfi: String?) -> ExportRecord {
        ExportRecord(annotation: .init(annotation: annotation(pk: pk, assetID: assetID, selectedText: "quote", cfi: cfi), source: .unmapped))
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
        cfi: String? = nil,
        representativeText: String? = nil
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
            representativeText: representativeText,
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

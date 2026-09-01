import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("JSONExporterTests")
struct JSONExporterTests {
    @Test
    func singleFilePreservesSourceSpecificRawFieldsMetadataAndWarnings() throws {
        let fixture = try Fixture()
        let data = try JSONExporter.render(fixture.bundle, exportedAt: fixture.exportedAt)
        let root = try object(data)

        #expect(root["schemaVersion"] as? Int == 1)
        #expect(root["exportedAt"] as? String == "2023-11-14T22:13:20.125Z")

        let options = try dictionary(root["options"])
        #expect(options["source"] as? String == "all")
        #expect(options["kinds"] as? [String] == ["bookmark", "highlight", "note"])
        #expect(options["colors"] as? [String] == ["blue", "yellow"])
        #expect(options["order"] as? String == "reading")
        #expect(options["skipFirstPerBook"] as? Int == 2)
        #expect(options["grouping"] as? String == "perBook")
        #expect(options["includeEPUBMetadata"] as? Bool == true)
        #expect(options["cover"] as? String == "inline")
        let selectors = try array(options["bookSelectors"])
        #expect(try dictionary(selectors[0])["kind"] as? String == "assetID")
        #expect(try dictionary(selectors[0])["value"] as? String == "current-asset")
        #expect(try dictionary(selectors[1])["kind"] as? String == "pdfFile")
        #expect(try dictionary(selectors[1])["value"] as? String == fixture.pdfURL.path)

        let statistics = try dictionary(root["statistics"])
        #expect(statistics["documentCount"] as? Int == 3)
        #expect(statistics["recordCount"] as? Int == 3)
        #expect(statistics["historicalEPUBAnnotationCount"] as? Int == 0)
        #expect(statistics["unmappedEPUBAnnotationCount"] as? Int == 1)
        let sourceTotals = try dictionary(root["sourceTotals"])
        #expect(sourceTotals["epubAnnotationCount"] as? Int == 4)
        #expect(sourceTotals["pdfAttemptedDocumentCount"] as? Int == 2)
        #expect(sourceTotals["pdfFailedDocumentCount"] as? Int == 1)

        let groups = try array(root["groups"])
        #expect(groups.count == 3)

        let orphan = try dictionary(groups[0])
        let orphanSource = try dictionary(orphan["source"])
        #expect(orphanSource["kind"] as? String == "epubUnmapped")
        #expect(orphanSource["assetID"] as? String == "orphan-asset")
        let orphanRecord = try dictionary(try array(orphan["records"])[0])
        #expect(orphanRecord["source"] as? String == "epub")
        #expect(orphanRecord["pdfHighlight"] == nil)
        let orphanAnnotation = try dictionary(orphanRecord["annotation"])
        #expect(orphanAnnotation["localPK"] as? Int == 21)
        #expect(orphanAnnotation["uuid"] as? String == "annotation-uuid")
        #expect(orphanAnnotation["rawAssetID"] as? String == "orphan-asset")
        #expect(orphanAnnotation["type"] as? Int == 77)
        #expect(orphanAnnotation["style"] as? Int == 2)
        #expect(orphanAnnotation["note"] == nil)
        #expect(orphanAnnotation["modifiedAt"] == nil)
        let location = try dictionary(orphanAnnotation["location"])
        #expect(location["rawCFI"] as? String == fixture.rawCFI)

        let current = try dictionary(groups[1])
        let currentSource = try dictionary(current["source"])
        #expect(currentSource["kind"] as? String == "epubCurrent")
        let currentBook = try dictionary(currentSource["book"])
        #expect(currentBook["assetID"] as? String == "current-asset")
        #expect(currentBook["genresRawBase64"] as? String == "AAH/")
        #expect(currentBook["creationDate"] as? String == "2020-09-13T12:26:40.500Z")
        #expect(currentBook["normalizedAuthor"] == nil)
        let metadata = try dictionary(current["epubMetadata"])
        #expect(metadata["publisher"] as? String == "Publisher")
        #expect(metadata["coverItemID"] as? String == "cover-item")
        let cover = try dictionary(current["epubCover"])
        #expect(cover["dataBase64"] as? String == "iVBORw==")
        #expect(cover["declaredMediaType"] as? String == "image/jpeg")
        #expect(cover["detectedMediaType"] as? String == "image/png")
        #expect(cover["mediaType"] as? String == "image/png")
        #expect(cover["source"] as? String == "manifestProperty")

        let pdf = try dictionary(groups[2])
        let pdfSource = try dictionary(try dictionary(pdf["source"])["pdfSource"])
        #expect(pdfSource["filePath"] as? String == fixture.pdfURL.path)
        #expect(pdfSource["displayTitle"] as? String == "export-test")
        #expect(pdfSource["book"] == nil)
        let pdfRecord = try dictionary(try array(pdf["records"])[0])
        #expect(pdfRecord["source"] as? String == "pdf")
        #expect(pdfRecord["annotation"] == nil)
        let highlight = try dictionary(pdfRecord["pdfHighlight"])
        #expect(highlight["page"] as? Int == 4)
        #expect(highlight["traversalIndex"] as? Int == 7)
        #expect(highlight["pdfKitRGBA"] as? [Double] == [0.1, 0.2, 0.3, 1.0])
        #expect(highlight["modifiedAt"] as? String == "2020-09-13T12:26:40.500Z")
        #expect(highlight["text"] as? String == "pdf quote")
        #expect(highlight["textSource"] as? String == "quadSelection")
        #expect(highlight["textIsApproximate"] as? Bool == true)
        #expect(highlight["textUnavailableReason"] == nil)
        let color = try dictionary(highlight["presentationColor"])
        #expect(color["color"] as? String == "yellow")
        #expect(color["distance"] as? Double == 0.125)
        #expect(color["isApproximate"] as? Bool == true)

        let warnings = try array(root["warnings"])
        #expect(warnings.count == 2)
        #expect(try dictionary(warnings[0])["code"] as? String == "epubCoverUnavailable")
        let pdfWarning = try dictionary(warnings[1])
        #expect(pdfWarning["code"] as? String == "pdfFailure")
        let failure = try dictionary(pdfWarning["pdfFailure"])
        #expect(failure["kind"] as? String == "worker")
        let workerError = try dictionary(failure["workerError"])
        #expect(workerError["code"] as? String == "workerFailure")
        #expect(workerError["workerCode"] as? String == "unreadableDocument")
    }

    @Test
    func historicalSourceKeepsRawAssetIdentityWithoutInventingCurrentBook() throws {
        let annotation = Annotation(
            localPK: 31,
            uuid: nil,
            rawAssetID: "historical-asset",
            isDeleted: false,
            isUnderline: nil,
            style: nil,
            type: 1,
            createdAt: nil,
            modifiedAt: nil,
            representativeText: nil,
            selectedText: "historical quote",
            note: nil,
            location: nil,
            chapterHint: nil,
            physicalLocation: nil,
            rangeStart: nil,
            rangeEnd: nil
        )
        let group = ExportGroup(
            source: .epubHistorical(
                assetID: "historical-asset",
                metadata: HistoricalBookMetadata(title: "Historical Title", author: "Historical Author")
            ),
            records: [
                ExportRecord(
                    payload: .epub(
                        EnrichedAnnotation(
                            annotation: annotation,
                            source: .historicalInferred(
                                HistoricalBookMetadata(title: "Historical Title", author: "Historical Author")
                            )
                        )
                    )
                ),
            ]
        )
        let base = try Fixture()

        let document = try object(
            JSONExporter.renderDocument(group, from: base.bundle, exportedAt: base.exportedAt)
        )
        let source = try dictionary(try dictionary(document["group"])["source"])

        #expect(source["kind"] as? String == "epubHistorical")
        #expect(source["assetID"] as? String == "historical-asset")
        #expect(source["book"] == nil)
        #expect(source["pdfSource"] == nil)
        let metadata = try dictionary(source["historicalMetadata"])
        #expect(metadata["title"] as? String == "Historical Title")
        #expect(metadata["author"] as? String == "Historical Author")
    }

    @Test
    func fixedTimestampAndSortedCollectionsProduceDeterministicBytes() throws {
        let fixture = try Fixture()

        let first = try JSONExporter.render(fixture.bundle, exportedAt: fixture.exportedAt)
        let second = try JSONExporter.render(fixture.bundle, exportedAt: fixture.exportedAt)

        #expect(first == second)
        let text = try #require(String(data: first, encoding: .utf8))
        #expect(text.contains("\"exportedAt\":\"2023-11-14T22:13:20.125Z\""))
        #expect(text.contains("\"kinds\":[\"bookmark\",\"highlight\",\"note\"]"))
        #expect(text.contains("\"colors\":[\"blue\",\"yellow\"]"))
    }

    @Test
    func perDocumentOutputReusesTheExactGroupDTOWithoutGlobalRunState() throws {
        let fixture = try Fixture()
        let full = try object(JSONExporter.render(fixture.bundle, exportedAt: fixture.exportedAt))
        let fullPDFGroup = try array(full["groups"])[2]

        let document = try object(
            JSONExporter.renderDocument(
                fixture.bundle.groups[2],
                from: fixture.bundle,
                exportedAt: fixture.exportedAt
            )
        )

        #expect(Set(document.keys) == ["schemaVersion", "exportedAt", "options", "group"])
        #expect(document["schemaVersion"] as? Int == 1)
        #expect(document["exportedAt"] as? String == "2023-11-14T22:13:20.125Z")
        #expect(document["statistics"] == nil)
        #expect(document["sourceTotals"] == nil)
        #expect(document["warnings"] == nil)
        #expect(document["groups"] == nil)
        #expect(try normalized(document["group"]) == normalized(fullPDFGroup))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try dictionary(JSONSerialization.jsonObject(with: data))
    }

    private func dictionary(_ value: Any?) throws -> [String: Any] {
        try #require(value as? [String: Any])
    }

    private func array(_ value: Any?) throws -> [Any] {
        try #require(value as? [Any])
    }

    private func normalized(_ value: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: try #require(value), options: [.sortedKeys])
    }

    private struct Fixture {
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let rawDate = Date(timeIntervalSince1970: 1_600_000_000.5)
        let rawCFI = "epubcfi(/6/4[chapter]!/4/2,:3,:9)"
        let pdfURL = URL(fileURLWithPath: "/tmp/export-test.pdf").standardizedFileURL
        let bundle: ExportBundle

        init() throws {
            let currentBook = Book(
                localPK: 11,
                assetID: "current-asset",
                title: "Current Book",
                author: "Author",
                description: "Description",
                epubID: "epub-id",
                genre: "Genre",
                genresRaw: Data([0x00, 0x01, 0xFF]),
                comments: "Comments",
                language: "en",
                year: 2020,
                contentType: 1,
                pageCount: 321,
                path: "/tmp/current.epub",
                fileSize: 4096,
                coverURL: "cover://raw",
                isFinished: false,
                readingProgressRaw: 0.25,
                durationRawMilliseconds: 12_345,
                creationDate: rawDate,
                modificationDate: nil,
                finishedDate: nil,
                lastOpenDate: rawDate,
                purchaseDate: nil,
                releaseDate: rawDate,
                isExplicit: false,
                isLocked: false,
                isEphemeral: false,
                isHidden: false,
                isSample: false,
                isStoreAudiobook: false,
                rating: 4.5
            )
            let orphanAnnotation = Annotation(
                localPK: 21,
                uuid: "annotation-uuid",
                rawAssetID: "orphan-asset",
                isDeleted: false,
                isUnderline: true,
                style: 2,
                type: 77,
                createdAt: rawDate,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: "orphan quote",
                note: nil,
                location: Location(rawCFI: rawCFI),
                chapterHint: "chapter",
                physicalLocation: 12,
                rangeStart: 3,
                rangeEnd: 9
            )
            let currentAnnotation = Annotation(
                localPK: 22,
                uuid: nil,
                rawAssetID: "current-asset",
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: nil,
                modifiedAt: rawDate,
                representativeText: "representative",
                selectedText: "current quote",
                note: "current note",
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            let pdfSource = PDFSource(fileURL: pdfURL, book: nil)
            let pdfHighlight = PDFHighlight(
                page: 4,
                traversalIndex: 7,
                bounds: CGRect(x: 1.25, y: 2.5, width: 30.75, height: 4.5),
                quadrilateralPoints: [
                    CGPoint(x: 1, y: 2),
                    CGPoint(x: 3, y: 2),
                    CGPoint(x: 1, y: 4),
                    CGPoint(x: 3, y: 4),
                ],
                note: nil,
                pdfKitRGBA: [0.1, 0.2, 0.3, 1.0],
                presentationColor: PDFColorMatch(color: .yellow, distance: 0.125, isApproximate: true),
                modifiedAt: rawDate,
                text: "pdf quote",
                textSource: .quadSelection,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
            let metadata = EPUBMetadata(
                title: "EPUB Title",
                creator: "EPUB Creator",
                identifiers: ["id-1", "id-2"],
                isbn: "9780306406157",
                language: "en",
                publisher: "Publisher",
                publicationDate: "2020-01-02",
                rights: "Rights",
                subjects: ["One", "Two"],
                coverItemID: "cover-item"
            )
            let cover = EPUBCover(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                declaredMediaType: "image/jpeg",
                detectedMediaType: "image/png",
                source: .manifestProperty
            )

            let groups = [
                ExportGroup(
                    source: .epubUnmapped(assetID: "orphan-asset"),
                    records: [ExportRecord(payload: .epub(EnrichedAnnotation(annotation: orphanAnnotation, source: .unmapped)))]
                ),
                ExportGroup(
                    source: .epubCurrent(currentBook),
                    records: [
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(annotation: currentAnnotation, source: .currentLibrary(currentBook))
                            )
                        ),
                    ],
                    epubMetadata: metadata,
                    epubCover: cover
                ),
                ExportGroup(
                    source: .pdf(pdfSource),
                    records: [ExportRecord(payload: .pdf(source: pdfSource, highlight: pdfHighlight))]
                ),
            ]
            let options = try ExportOptions(
                source: .all,
                bookSelectors: [.assetID("current-asset"), .pdfFile(pdfURL)],
                kinds: [.note, .highlight, .bookmark],
                colors: [.yellow, .blue],
                order: .reading,
                skipFirstPerBook: 2,
                grouping: .perBook,
                includeEPUBMetadata: true,
                cover: .inline
            )
            bundle = ExportBundle(
                options: options,
                groups: groups,
                warnings: [
                    .epubCoverUnavailable(bookLocalPK: 11),
                    .pdfFailure(
                        PDFHighlightServiceFailure(
                            source: pdfSource,
                            reason: .worker(.workerFailure(.unreadableDocument))
                        )
                    ),
                ],
                statistics: ExportStatistics(
                    documentCount: 3,
                    epubDocumentCount: 2,
                    pdfDocumentCount: 1,
                    recordCount: 3,
                    epubAnnotationCount: 2,
                    pdfHighlightCount: 1,
                    highlightCount: 2,
                    noteCount: 1,
                    bookmarkCount: 0,
                    historicalEPUBAnnotationCount: 0,
                    unmappedEPUBAnnotationCount: 1
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: 3,
                    epubAnnotationCount: 4,
                    pdfAttemptedDocumentCount: 2,
                    pdfSucceededDocumentCount: 1,
                    pdfFailedDocumentCount: 1,
                    pdfHighlightCount: 1
                )
            )
        }
    }
}

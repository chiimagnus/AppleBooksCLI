import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("CSVExporterTests")
struct CSVExporterTests {
    @Test
    func outputUsesUTF8BOMFixedHeaderAndCRLF() throws {
        let fixture = try Fixture()
        let data = CSVExporter.render(fixture.bundle)

        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let body = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        #expect(body.hasPrefix(CSVExporter.columns.joined(separator: ",") + "\r\n"))
        #expect(body.hasSuffix("\r\n"))

        let rows = try parse(data)
        #expect(rows.count == 5)
        #expect(rows[0] == CSVExporter.columns)
        #expect(rows.dropFirst().allSatisfy { $0.count == CSVExporter.columns.count })
    }

    @Test
    func perDocumentOutputKeepsTheSameSchemaAndOnlyTheSelectedGroup() throws {
        let fixture = try Fixture()
        let group = try #require(fixture.bundle.groups.dropFirst().first)
        let rows = try parse(CSVExporter.renderDocument(group))

        #expect(rows.count == 2)
        #expect(rows[0] == CSVExporter.columns)
        let row = dictionary(header: rows[0], row: rows[1])
        #expect(row["source_kind"] == "epubHistorical")
        #expect(row["source_asset_id"] == "history")
        #expect(row["book_asset_id"] == "")
        #expect(row["pdf_file_path"] == "")
    }

    @Test
    func roundTripEscapesUnicodePDFAndOrphansWhileFormulaNeutralizationIsPresentationOnly() throws {
        let fixture = try Fixture()
        let data = CSVExporter.render(fixture.bundle)
        let rows = try parse(data)
        let header = rows[0]
        let current = dictionary(header: header, row: rows[1])
        let historical = dictionary(header: header, row: rows[2])
        let orphan = dictionary(header: header, row: rows[3])
        let pdf = dictionary(header: header, row: rows[4])

        #expect(current["source"] == "epub")
        #expect(current["source_kind"] == "epubCurrent")
        #expect(current["source_asset_id"] == "'=cmd")
        #expect(current["book_asset_id"] == "'=cmd")
        #expect(current["book_title"] == "'+SUM(A1:A2)")
        #expect(current["book_author"] == "'-1+2")
        #expect(current["annotation_uuid"] == "'@name")
        #expect(current["annotation_representative_text"] == "'\tvalue")
        #expect(current["annotation_note"] == "'\rvalue")
        #expect(current["annotation_cfi"] == "'\nvalue")
        #expect(current["annotation_apple_books_url"] == fixture.currentAnnotation.appleBooksURL)
        #expect(current["annotation_type"] == "-7")
        #expect(current["text"] == fixture.multilineText)
        #expect(current["annotation_selected_text"] == fixture.multilineText)
        #expect(current["note"] == "'\rvalue")
        #expect(current["pdf_page"] == "")

        #expect(historical["source_kind"] == "epubHistorical")
        #expect(historical["source_asset_id"] == "history")
        #expect(historical["historical_title"] == "'@Historical")
        #expect(historical["historical_author"] == "'\tArchive")
        #expect(historical["is_historical"] == "true")
        #expect(historical["is_unmapped"] == "false")
        #expect(historical["book_local_pk"] == "")

        #expect(orphan["source_kind"] == "epubUnmapped")
        #expect(orphan["source_asset_id"] == "orphan")
        #expect(orphan["is_historical"] == "false")
        #expect(orphan["is_unmapped"] == "true")
        #expect(orphan["historical_title"] == "")

        #expect(pdf["source"] == "pdf")
        #expect(pdf["source_kind"] == "pdf")
        #expect(pdf["annotation_uuid"] == "")
        #expect(pdf["annotation_apple_books_url"] == "")
        #expect(pdf["pdf_page"] == "2")
        #expect(pdf["pdf_traversal_index"] == "3")
        #expect(pdf["pdf_bounds_x"] == "-1.5")
        #expect(pdf["pdf_quad_points"] == "1.0:2.0;3.0:2.0;1.0:4.0;3.0:4.0")
        #expect(pdf["text"] == "'=PDF()")
        #expect(pdf["note"] == "'+PDFNOTE")
        #expect(pdf["pdf_text"] == "'=PDF()")
        #expect(pdf["pdf_note"] == "'+PDFNOTE")
        #expect(pdf["pdf_text_source"] == "boundsFallback")
        #expect(pdf["pdf_presentation_color"] == "purple")
        #expect(pdf["pdf_color_is_approximate"] == "true")
        #expect(pdf["pdf_kit_rgba_r"] == "-0.1")
        #expect(pdf["pdf_kit_rgba_a"] == "1.0")

        // CSV presentation escaping must never mutate the canonical bundle.
        #expect(fixture.currentBook.assetID == "=cmd")
        #expect(fixture.currentBook.title == "+SUM(A1:A2)")
        #expect(fixture.currentBook.author == "-1+2")
        #expect(fixture.currentAnnotation.uuid == "@name")
        #expect(fixture.currentAnnotation.representativeText == "\tvalue")
        #expect(fixture.currentAnnotation.note == "\rvalue")
        #expect(fixture.currentAnnotation.location?.rawCFI == "\nvalue")
        #expect(fixture.currentAnnotation.type == -7)

        let json = try JSONSerialization.jsonObject(
            with: JSONExporter.render(fixture.bundle, exportedAt: fixture.exportedAt)
        ) as? [String: Any]
        let jsonGroups = try #require(json?["groups"] as? [[String: Any]])
        let jsonCurrentSource = try #require(jsonGroups[0]["source"] as? [String: Any])
        let jsonBook = try #require(jsonCurrentSource["book"] as? [String: Any])
        #expect(jsonBook["assetID"] as? String == "=cmd")
        #expect(jsonBook["title"] as? String == "+SUM(A1:A2)")
        let jsonRecord = try #require((jsonGroups[0]["records"] as? [[String: Any]])?.first)
        let jsonAnnotation = try #require(jsonRecord["annotation"] as? [String: Any])
        #expect(jsonAnnotation["uuid"] as? String == "@name")
        #expect(jsonAnnotation["note"] as? String == "\rvalue")
    }

    private func dictionary(header: [String], row: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(header, row))
    }

    private func parse(_ data: Data) throws -> [[String]] {
        #expect(Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF])
        let text = try #require(String(data: data.dropFirst(3), encoding: .utf8))
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuotes {
                if character == "\"" {
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = text.index(after: next)
                        continue
                    }
                    inQuotes = false
                } else {
                    field.append(character)
                }
                index = next
                continue
            }

            switch character {
            case "\"":
                guard field.isEmpty else { throw CSVTestError.invalidCSV }
                inQuotes = true
                index = next
            case ",":
                row.append(field)
                field = ""
                index = next
            case "\r\n":
                row.append(field)
                rows.append(row)
                field = ""
                row = []
                index = next
            case "\r", "\n":
                throw CSVTestError.invalidCSV
            default:
                field.append(character)
                index = next
            }
        }

        guard inQuotes == false, field.isEmpty, row.isEmpty else { throw CSVTestError.invalidCSV }
        return rows
    }

    private struct Fixture {
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let rawDate = Date(timeIntervalSince1970: 1_600_000_000.5)
        let multilineText = "value,\"quoted\"\n中文"
        let currentBook: Book
        let currentAnnotation: Annotation
        let bundle: ExportBundle

        init() throws {
            currentBook = Self.book(assetID: "=cmd", title: "+SUM(A1:A2)", author: "-1+2", date: rawDate)
            currentAnnotation = Annotation(
                localPK: 11,
                uuid: "@name",
                rawAssetID: "=cmd",
                isDeleted: false,
                isUnderline: true,
                style: 2,
                type: -7,
                createdAt: rawDate,
                modifiedAt: nil,
                representativeText: "\tvalue",
                selectedText: multilineText,
                note: "\rvalue",
                location: Location(rawCFI: "\nvalue"),
                chapterHint: "chapter",
                physicalLocation: 10,
                rangeStart: 20,
                rangeEnd: 30
            )
            let historicalMetadata = HistoricalBookMetadata(title: "@Historical", author: "\tArchive")
            let historicalAnnotation = Annotation(
                localPK: 12,
                uuid: nil,
                rawAssetID: "history",
                isDeleted: false,
                isUnderline: false,
                style: 3,
                type: 1,
                createdAt: nil,
                modifiedAt: rawDate,
                representativeText: nil,
                selectedText: "history quote",
                note: nil,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            let orphanAnnotation = Annotation(
                localPK: 13,
                uuid: nil,
                rawAssetID: "orphan",
                isDeleted: false,
                isUnderline: nil,
                style: nil,
                type: 1,
                createdAt: nil,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: "orphan quote",
                note: nil,
                location: nil,
                chapterHint: nil,
                physicalLocation: nil,
                rangeStart: nil,
                rangeEnd: nil
            )
            let pdfSource = PDFSource(
                fileURL: URL(fileURLWithPath: "/tmp/export.csv.pdf").standardizedFileURL,
                book: nil
            )
            let pdfHighlight = PDFHighlight(
                page: 2,
                traversalIndex: 3,
                bounds: CGRect(x: -1.5, y: 2.0, width: 30.0, height: 4.0),
                quadrilateralPoints: [
                    CGPoint(x: 1, y: 2),
                    CGPoint(x: 3, y: 2),
                    CGPoint(x: 1, y: 4),
                    CGPoint(x: 3, y: 4),
                ],
                note: "+PDFNOTE",
                pdfKitRGBA: [-0.1, 0.2, 0.3, 1.0],
                presentationColor: PDFColorMatch(color: .purple, distance: 0.25, isApproximate: true),
                modifiedAt: rawDate,
                text: "=PDF()",
                textSource: .boundsFallback,
                textIsApproximate: true,
                textUnavailableReason: nil
            )

            let groups = [
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
                    source: .epubHistorical(assetID: "history", metadata: historicalMetadata),
                    records: [
                        ExportRecord(
                            payload: .epub(
                                EnrichedAnnotation(
                                    annotation: historicalAnnotation,
                                    source: .historicalInferred(historicalMetadata)
                                )
                            )
                        ),
                    ]
                ),
                ExportGroup(
                    source: .epubUnmapped(assetID: "orphan"),
                    records: [
                        ExportRecord(payload: .epub(EnrichedAnnotation(annotation: orphanAnnotation, source: .unmapped))),
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
                    documentCount: 4,
                    epubDocumentCount: 3,
                    pdfDocumentCount: 1,
                    recordCount: 4,
                    epubAnnotationCount: 3,
                    pdfHighlightCount: 1,
                    highlightCount: 4,
                    noteCount: 0,
                    bookmarkCount: 0,
                    historicalEPUBAnnotationCount: 1,
                    unmappedEPUBAnnotationCount: 1
                ),
                sourceTotals: ExportSourceTotals(
                    epubDocumentCount: 3,
                    epubAnnotationCount: 3,
                    pdfAttemptedDocumentCount: 1,
                    pdfSucceededDocumentCount: 1,
                    pdfFailedDocumentCount: 0,
                    pdfHighlightCount: 1
                )
            )
        }

        private static func book(assetID: String, title: String, author: String, date: Date) -> Book {
            Book(
                localPK: 1,
                assetID: assetID,
                title: title,
                author: author,
                description: nil,
                epubID: nil,
                genre: nil,
                genresRaw: nil,
                comments: nil,
                language: nil,
                year: nil,
                contentType: 1,
                pageCount: nil,
                path: "/tmp/current.epub",
                fileSize: nil,
                coverURL: nil,
                isFinished: nil,
                readingProgressRaw: nil,
                durationRawMilliseconds: nil,
                creationDate: date,
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

    private enum CSVTestError: Error {
        case invalidCSV
    }
}

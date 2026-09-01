import CoreGraphics
import Foundation

public enum CSVExporter {
    static let columns = [
        "source",
        "source_kind",
        "source_asset_id",
        "book_local_pk",
        "book_asset_id",
        "book_title",
        "book_author",
        "historical_title",
        "historical_author",
        "is_historical",
        "is_unmapped",
        "pdf_file_path",
        "pdf_display_title",
        "presentation_kind",
        "presentation_color",
        "presentation_underline",
        "text",
        "note",
        "annotation_local_pk",
        "annotation_uuid",
        "annotation_raw_asset_id",
        "annotation_deleted",
        "annotation_underline_raw",
        "annotation_style",
        "annotation_type",
        "annotation_created_at",
        "annotation_modified_at",
        "annotation_representative_text",
        "annotation_selected_text",
        "annotation_note",
        "annotation_cfi",
        "annotation_chapter_hint",
        "annotation_physical_location",
        "annotation_range_start",
        "annotation_range_end",
        "pdf_page",
        "pdf_traversal_index",
        "pdf_bounds_x",
        "pdf_bounds_y",
        "pdf_bounds_width",
        "pdf_bounds_height",
        "pdf_quad_points",
        "pdf_note",
        "pdf_modified_at",
        "pdf_text",
        "pdf_text_source",
        "pdf_text_is_approximate",
        "pdf_text_unavailable_reason",
        "pdf_presentation_color",
        "pdf_color_distance",
        "pdf_color_is_approximate",
        "pdf_kit_rgba_r",
        "pdf_kit_rgba_g",
        "pdf_kit_rgba_b",
        "pdf_kit_rgba_a",
    ]

    public static func render(_ bundle: ExportBundle) -> Data {
        let mapper = CSVRowMapper()
        var output = columns.map(csvQuote).joined(separator: ",") + "\r\n"
        for group in bundle.groups {
            for record in group.records {
                output += mapper.row(group: group, record: record)
                    .map(renderCell)
                    .joined(separator: ",")
                output += "\r\n"
            }
        }

        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(contentsOf: output.utf8)
        return data
    }

    private static func renderCell(_ cell: CSVCell) -> String {
        switch cell {
        case let .untrusted(value):
            return csvQuote(neutralizeFormula(value ?? ""))
        case let .trusted(value):
            return csvQuote(value ?? "")
        }
    }

    private static func neutralizeFormula(_ value: String) -> String {
        guard let first = value.first,
              first == "=" || first == "+" || first == "-" || first == "@" ||
              first == "\t" || first == "\r" || first == "\n" else {
            return value
        }
        return "'" + value
    }

    private static func csvQuote(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

private enum CSVCell {
    case untrusted(String?)
    case trusted(String?)
}

private struct CSVRowMapper {
    private let formatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter
    }

    func row(group: ExportGroup, record: ExportRecord) -> [CSVCell] {
        let source = sourceContext(group.source)
        let common = commonRecord(record)
        let annotation = epubAnnotation(record)
        let highlight = pdfHighlight(record)
        return [
            .trusted(common.source),
            .trusted(source.kind),
            .untrusted(source.sourceAssetID),
            integer(source.book?.localPK),
            .untrusted(source.book?.assetID),
            .untrusted(source.book?.title),
            .untrusted(source.book?.author),
            .untrusted(source.historical?.title),
            .untrusted(source.historical?.author),
            boolean(source.isHistorical),
            boolean(source.isUnmapped),
            .untrusted(source.pdfSource?.fileURL.path),
            .untrusted(source.pdfSource?.displayTitle),
            .trusted(record.presentationKind.rawValue),
            .trusted(record.presentationColor?.rawValue),
            boolean(record.isUnderline),
            .untrusted(common.text),
            .untrusted(common.note),
            integer(annotation?.localPK),
            .untrusted(annotation?.uuid),
            .untrusted(annotation?.rawAssetID),
            boolean(annotation?.isDeleted),
            boolean(annotation?.isUnderline),
            integer(annotation?.style),
            integer(annotation?.type),
            date(annotation?.createdAt),
            date(annotation?.modifiedAt),
            .untrusted(annotation?.representativeText),
            .untrusted(annotation?.selectedText),
            .untrusted(annotation?.note),
            .untrusted(annotation?.location?.rawCFI),
            .untrusted(annotation?.chapterHint),
            integer(annotation?.physicalLocation),
            integer(annotation?.rangeStart),
            integer(annotation?.rangeEnd),
            integer(highlight?.page),
            integer(highlight?.traversalIndex),
            double(highlight.map { Double($0.bounds.origin.x) }),
            double(highlight.map { Double($0.bounds.origin.y) }),
            double(highlight.map { Double($0.bounds.size.width) }),
            double(highlight.map { Double($0.bounds.size.height) }),
            .trusted(highlight.map(quadPoints)),
            .untrusted(highlight?.note),
            date(highlight?.modifiedAt),
            .untrusted(highlight?.text),
            .trusted(highlight?.textSource?.rawValue),
            boolean(highlight?.textIsApproximate),
            .trusted(highlight?.textUnavailableReason?.rawValue),
            .trusted(highlight?.presentationColor?.color.rawValue),
            double(highlight?.presentationColor?.distance),
            boolean(highlight?.presentationColor?.isApproximate),
            double(rgba(highlight, index: 0)),
            double(rgba(highlight, index: 1)),
            double(rgba(highlight, index: 2)),
            double(rgba(highlight, index: 3)),
        ]
    }

    private func sourceContext(_ source: ExportGroupSource) -> SourceContext {
        switch source {
        case let .epubCurrent(book):
            return SourceContext(kind: "epubCurrent", sourceAssetID: book.assetID, book: book)
        case let .epubHistorical(assetID, metadata):
            return SourceContext(
                kind: "epubHistorical",
                sourceAssetID: assetID,
                historical: metadata,
                isHistorical: true
            )
        case let .epubUnmapped(assetID):
            return SourceContext(kind: "epubUnmapped", sourceAssetID: assetID, isUnmapped: true)
        case let .pdf(source):
            return SourceContext(kind: "pdf", sourceAssetID: source.book?.assetID, book: source.book, pdfSource: source)
        }
    }

    private func commonRecord(_ record: ExportRecord) -> (source: String, text: String?, note: String?) {
        switch record.payload {
        case let .epub(enriched):
            return (
                "epub",
                enriched.annotation.selectedText ?? enriched.annotation.representativeText,
                enriched.annotation.note
            )
        case let .pdf(_, highlight):
            return ("pdf", highlight.text, highlight.note)
        }
    }

    private func epubAnnotation(_ record: ExportRecord) -> Annotation? {
        switch record.payload {
        case let .epub(enriched): enriched.annotation
        case .pdf: nil
        }
    }

    private func pdfHighlight(_ record: ExportRecord) -> PDFHighlight? {
        switch record.payload {
        case .epub: nil
        case let .pdf(_, highlight): highlight
        }
    }

    private func date(_ value: Date?) -> CSVCell {
        .trusted(value.map { formatter.string(from: $0) })
    }

    private func integer<T: BinaryInteger>(_ value: T?) -> CSVCell {
        .trusted(value.map { String($0) })
    }

    private func double(_ value: Double?) -> CSVCell {
        .trusted(value.map { String($0) })
    }

    private func boolean(_ value: Bool?) -> CSVCell {
        .trusted(value.map { $0 ? "true" : "false" })
    }

    private func quadPoints(_ highlight: PDFHighlight) -> String {
        highlight.quadrilateralPoints
            .map { "\(Double($0.x)):\(Double($0.y))" }
            .joined(separator: ";")
    }

    private func rgba(_ highlight: PDFHighlight?, index: Int) -> Double? {
        guard let values = highlight?.pdfKitRGBA, values.indices.contains(index) else { return nil }
        return values[index]
    }
}

private struct SourceContext {
    let kind: String
    let sourceAssetID: String?
    let book: Book?
    let historical: HistoricalBookMetadata?
    let pdfSource: PDFSource?
    let isHistorical: Bool
    let isUnmapped: Bool

    init(
        kind: String,
        sourceAssetID: String? = nil,
        book: Book? = nil,
        historical: HistoricalBookMetadata? = nil,
        pdfSource: PDFSource? = nil,
        isHistorical: Bool = false,
        isUnmapped: Bool = false
    ) {
        self.kind = kind
        self.sourceAssetID = sourceAssetID
        self.book = book
        self.historical = historical
        self.pdfSource = pdfSource
        self.isHistorical = isHistorical
        self.isUnmapped = isUnmapped
    }
}

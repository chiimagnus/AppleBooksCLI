import CoreGraphics
import Foundation

package enum JSONExporter {
    static let schemaVersion = 9

    package static func stream(
        _ bundle: ExportBundle,
        exportedAt: Date,
        observeBufferedBytes: ((Int) -> Void)? = nil,
        to sink: (Data) throws -> Void
    ) throws {
        try withoutActuallyEscaping(sink) { escapingSink in
            let writer = StreamingJSONWriter(sink: escapingSink, observeBufferedBytes: observeBufferedBytes)
            try writer.writeBundle(bundle, exportedAt: exportedAt)
            try writer.finish()
        }
    }

    package static func streamDocument(
        _ group: ExportGroup,
        from bundle: ExportBundle,
        exportedAt: Date,
        observeBufferedBytes: ((Int) -> Void)? = nil,
        to sink: (Data) throws -> Void
    ) throws {
        try withoutActuallyEscaping(sink) { escapingSink in
            let writer = StreamingJSONWriter(sink: escapingSink, observeBufferedBytes: observeBufferedBytes)
            try writer.writeDocument(group, from: bundle, exportedAt: exportedAt)
            try writer.finish()
        }
    }
}

private struct JSONBookNumericProjection {
    let readingProgressRaw: Double?
    let durationRawMilliseconds: Double?
    let rating: Double?
    let anomalies: [JSONNumericAnomalyDTO]

    init(_ value: Book) {
        var anomalies: [JSONNumericAnomalyDTO] = []
        readingProgressRaw = Self.jsonNumber(value.readingProgressRaw, field: .readingProgressRaw, anomalies: &anomalies)
        durationRawMilliseconds = Self.jsonNumber(value.durationRawMilliseconds, field: .durationRawMilliseconds, anomalies: &anomalies)
        rating = Self.jsonNumber(value.rating, field: .rating, anomalies: &anomalies)
        self.anomalies = anomalies
    }

    private static func jsonNumber(
        _ value: Double?,
        field: JSONNumericAnomalyField,
        anomalies: inout [JSONNumericAnomalyDTO]
    ) -> Double? {
        guard let value else { return nil }
        if value.isFinite { return value }
        if value == .infinity {
            anomalies.append(JSONNumericAnomalyDTO(field: field, kind: .positiveInfinity))
        } else if value == -.infinity {
            anomalies.append(JSONNumericAnomalyDTO(field: field, kind: .negativeInfinity))
        }
        return nil
    }
}

private enum JSONNumericAnomalyField: String {
    case readingProgressRaw
    case durationRawMilliseconds
    case rating
}

private enum JSONNumericAnomalyKind: String {
    case positiveInfinity
    case negativeInfinity
}

private struct JSONNumericAnomalyDTO {
    let field: JSONNumericAnomalyField
    let kind: JSONNumericAnomalyKind
}

private enum StreamingJSONError: Error {
    case nonFiniteNumber
}

private final class StreamingJSONWriter {
    private static let base64Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    private let sink: (Data) throws -> Void
    private let observeBufferedBytes: ((Int) -> Void)?
    private var buffer: [UInt8] = []
    private let dateFormatter: ISO8601DateFormatter

    init(sink: @escaping (Data) throws -> Void, observeBufferedBytes: ((Int) -> Void)?) {
        self.sink = sink
        self.observeBufferedBytes = observeBufferedBytes
        buffer.reserveCapacity(ExportFileWriter.maximumChunkBytes)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter = formatter
    }

    func finish() throws {
        try flush()
    }

    func writeBundle(_ bundle: ExportBundle, exportedAt: Date) throws {
        try object { first in
            try field("schemaVersion", first: &first) { try integer(JSONExporter.schemaVersion) }
            try field("exportedAt", first: &first) { try string(dateFormatter.string(from: exportedAt)) }
            try field("options", first: &first) { try writeOptions(bundle.options) }
            try field("statistics", first: &first) { try writeStatistics(bundle.statistics) }
            try field("sourceTotals", first: &first) { try writeSourceTotals(bundle.sourceTotals) }
            try field("warnings", first: &first) { try array(bundle.warnings, writeWarning) }
            try field("groups", first: &first) { try array(bundle.groups, writeGroup) }
        }
    }

    func writeDocument(_ group: ExportGroup, from bundle: ExportBundle, exportedAt: Date) throws {
        try object { first in
            try field("schemaVersion", first: &first) { try integer(JSONExporter.schemaVersion) }
            try field("exportedAt", first: &first) { try string(dateFormatter.string(from: exportedAt)) }
            try field("options", first: &first) { try writeOptions(bundle.options) }
            try field("group", first: &first) { try writeGroup(group) }
        }
    }

    private func writeOptions(_ value: ExportOptions) throws {
        try object { first in
            try field("source", first: &first) { try string(value.source.rawValue) }
            try field("bookSelectors", first: &first) {
                try array(value.bookSelectors) { selector in
                    try object { selectorFirst in
                        let kind: String
                        let rawValue: String
                        switch selector {
                        case let .assetID(assetID):
                            kind = "assetID"; rawValue = assetID
                        case let .localPK(localPK):
                            kind = "localPK"; rawValue = String(localPK)
                        case let .pdfSourceID(sourceID):
                            kind = "pdfSourceID"; rawValue = sourceID
                        }
                        try field("kind", first: &selectorFirst) { try string(kind) }
                        try field("value", first: &selectorFirst) { try string(rawValue) }
                    }
                }
            }
            try optionalField("hasHighlight", value: value.hasHighlight, first: &first, write: boolean)
            try optionalField("hasNote", value: value.hasNote, first: &first, write: boolean)
            if let colors = value.colors {
                try field("colors", first: &first) { try array(colors.map(\.rawValue).sorted(), string) }
            }
            try optionalField("underline", value: value.underline, first: &first, write: boolean)
            try field("order", first: &first) { try string(value.order.rawValue) }
            try field("grouping", first: &first) { try string(value.grouping.rawValue) }
        }
    }

    private func writeGroup(_ value: ExportGroup) throws {
        try object { first in
            try field("source", first: &first) { try writeGroupSource(value.source) }
            try field("records", first: &first) { try array(value.records, writeRecord) }
        }
    }

    private func writeGroupSource(_ value: ExportGroupSource) throws {
        try object { first in
            switch value {
            case let .epubCurrent(book):
                try field("kind", first: &first) { try string("epubCurrent") }
                try field("book", first: &first) { try writeBook(book) }
            case let .epubHistorical(assetID, metadata):
                try field("kind", first: &first) { try string("epubHistorical") }
                try optionalField("assetID", value: assetID, first: &first, write: string)
                try field("historicalMetadata", first: &first) { try writeHistoricalMetadata(metadata) }
            case let .epubUnmapped(assetID):
                try field("kind", first: &first) { try string("epubUnmapped") }
                try optionalField("assetID", value: assetID, first: &first, write: string)
            case let .pdf(source):
                try field("kind", first: &first) { try string("pdf") }
                try field("pdfSource", first: &first) { try writePDFSource(source) }
            }
        }
    }

    private func writeRecord(_ value: ExportRecord) throws {
        try object { first in
            switch value.payload {
            case let .epub(enriched):
                try field("source", first: &first) { try string("epub") }
                try field("presentation", first: &first) { try writePresentation(value) }
                try field("annotation", first: &first) { try writeAnnotation(enriched.annotation) }
            case let .pdf(_, highlight):
                try field("source", first: &first) { try string("pdf") }
                try field("presentation", first: &first) { try writePresentation(value) }
                try field("pdfHighlight", first: &first) { try writePDFHighlight(highlight) }
            }
        }
    }

    private func writePresentation(_ value: ExportRecord) throws {
        try object { first in
            try field("hasHighlight", first: &first) { try boolean(value.hasHighlight) }
            try field("hasNote", first: &first) { try boolean(value.hasNote) }
            try optionalField("color", value: value.presentationColor?.rawValue, first: &first, write: string)
            try field("underline", first: &first) { try boolean(value.isUnderline) }
        }
    }

    private func writeAnnotation(_ value: Annotation) throws {
        try object { first in
            try field("localPK", first: &first) { try integer(value.localPK) }
            try optionalField("uuid", value: value.uuid, first: &first, write: string)
            try optionalField("rawAssetID", value: value.rawAssetID, first: &first, write: string)
            try optionalField("isDeleted", value: value.isDeleted, first: &first, write: boolean)
            try optionalField("isUnderline", value: value.isUnderline, first: &first, write: boolean)
            try optionalField("style", value: value.style, first: &first, write: integer)
            try optionalField("type", value: value.type, first: &first, write: integer)
            try optionalField("createdAt", value: value.createdAt.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("modifiedAt", value: value.modifiedAt.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("representativeText", value: value.representativeText, first: &first, write: string)
            try optionalField("selectedText", value: value.selectedText, first: &first, write: string)
            try optionalField("note", value: value.note, first: &first, write: string)
            try optionalField("appleBooksURL", value: value.appleBooksURL, first: &first, write: string)
            if let location = value.location {
                try field("location", first: &first) { try writeLocation(location) }
            }
            try optionalField("chapterHint", value: value.chapterHint, first: &first, write: string)
            try optionalField("physicalLocation", value: value.physicalLocation, first: &first, write: integer)
            try optionalField("rangeStart", value: value.rangeStart, first: &first, write: integer)
            try optionalField("rangeEnd", value: value.rangeEnd, first: &first, write: integer)
        }
    }

    private func writeLocation(_ value: Location) throws {
        try object { first in
            try field("rawCFI", first: &first) { try string(value.rawCFI) }
            try optionalField("chapterID", value: value.chapterID, first: &first, write: string)
            if let range = value.characterRange {
                try field("characterRange", first: &first) {
                    try object { rangeFirst in
                        try field("start", first: &rangeFirst) { try integer(range.start) }
                        try field("end", first: &rangeFirst) { try integer(range.end) }
                    }
                }
            }
        }
    }

    private func writeBook(_ value: Book) throws {
        let numerics = JSONBookNumericProjection(value)
        try object { first in
            try field("localPK", first: &first) { try integer(value.localPK) }
            try optionalField("assetID", value: value.assetID, first: &first, write: string)
            try optionalField("title", value: value.title, first: &first, write: string)
            try optionalField("author", value: value.author, first: &first, write: string)
            try optionalField("description", value: value.description, first: &first, write: string)
            try optionalField("epubID", value: value.epubID, first: &first, write: string)
            try optionalField("genre", value: value.genre, first: &first, write: string)
            if let genresRaw = value.genresRaw {
                try field("genresRawBase64", first: &first) { try base64(genresRaw) }
            }
            try optionalField("comments", value: value.comments, first: &first, write: string)
            try optionalField("language", value: value.language, first: &first, write: string)
            try optionalField("year", value: value.year, first: &first, write: integer)
            try optionalField("contentType", value: value.contentType, first: &first, write: integer)
            try optionalField("pageCount", value: value.pageCount, first: &first, write: integer)
            try optionalField("path", value: value.path, first: &first, write: string)
            try optionalField("fileSize", value: value.fileSize, first: &first, write: integer)
            try optionalField("coverURL", value: value.coverURL, first: &first, write: string)
            try optionalField("isFinished", value: value.isFinished, first: &first, write: boolean)
            try field("readingProgressRaw", first: &first) { try nullableDouble(numerics.readingProgressRaw) }
            try field("durationRawMilliseconds", first: &first) { try nullableDouble(numerics.durationRawMilliseconds) }
            try optionalField("creationDate", value: value.creationDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("modificationDate", value: value.modificationDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("finishedDate", value: value.finishedDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("lastOpenDate", value: value.lastOpenDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("purchaseDate", value: value.purchaseDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("releaseDate", value: value.releaseDate.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("isExplicit", value: value.isExplicit, first: &first, write: boolean)
            try optionalField("isLocked", value: value.isLocked, first: &first, write: boolean)
            try optionalField("isEphemeral", value: value.isEphemeral, first: &first, write: boolean)
            try optionalField("isHidden", value: value.isHidden, first: &first, write: boolean)
            try optionalField("isSample", value: value.isSample, first: &first, write: boolean)
            try optionalField("isStoreAudiobook", value: value.isStoreAudiobook, first: &first, write: boolean)
            try field("rating", first: &first) { try nullableDouble(numerics.rating) }
            try field("numericAnomalies", first: &first) { try array(numerics.anomalies, writeNumericAnomaly) }
        }
    }

    private func writeNumericAnomaly(_ value: JSONNumericAnomalyDTO) throws {
        try object { first in
            try field("field", first: &first) { try string(value.field.rawValue) }
            try field("kind", first: &first) { try string(value.kind.rawValue) }
        }
    }

    private func writeHistoricalMetadata(_ value: HistoricalBookMetadata) throws {
        try object { first in
            try field("title", first: &first) { try string(value.title) }
            try field("author", first: &first) { try string(value.author) }
        }
    }

    private func writePDFSource(_ value: PDFSource) throws {
        try object { first in
            try field("filePath", first: &first) { try string(value.fileURL.path) }
            try field("displayTitle", first: &first) { try string(value.displayTitle) }
            if let book = value.book {
                try field("book", first: &first) { try writeBook(book) }
            }
        }
    }

    private func writePDFHighlight(_ value: PDFHighlight) throws {
        try object { first in
            try field("page", first: &first) { try integer(value.page) }
            try field("traversalIndex", first: &first) { try integer(value.traversalIndex) }
            try field("bounds", first: &first) { try writeRect(value.bounds) }
            try field("quadrilateralPoints", first: &first) { try array(value.quadrilateralPoints, writePoint) }
            try optionalField("note", value: value.note, first: &first, write: string)
            if let rgba = value.pdfKitRGBA {
                try field("pdfKitRGBA", first: &first) { try array(rgba, double) }
            }
            if let color = value.presentationColor {
                try field("presentationColor", first: &first) { try writeColor(color) }
            }
            try optionalField("modifiedAt", value: value.modifiedAt.map(dateFormatter.string(from:)), first: &first, write: string)
            try optionalField("text", value: value.text, first: &first, write: string)
            try optionalField("textSource", value: value.textSource?.rawValue, first: &first, write: string)
            try field("textIsApproximate", first: &first) { try boolean(value.textIsApproximate) }
            try optionalField("textUnavailableReason", value: value.textUnavailableReason?.rawValue, first: &first, write: string)
        }
    }

    private func writeRect(_ value: CGRect) throws {
        try object { first in
            try field("x", first: &first) { try double(Double(value.origin.x)) }
            try field("y", first: &first) { try double(Double(value.origin.y)) }
            try field("width", first: &first) { try double(Double(value.size.width)) }
            try field("height", first: &first) { try double(Double(value.size.height)) }
        }
    }

    private func writePoint(_ value: CGPoint) throws {
        try object { first in
            try field("x", first: &first) { try double(Double(value.x)) }
            try field("y", first: &first) { try double(Double(value.y)) }
        }
    }

    private func writeColor(_ value: PDFColorMatch) throws {
        try object { first in
            try field("color", first: &first) { try string(value.color.rawValue) }
            try field("distance", first: &first) { try double(value.distance) }
            try field("isApproximate", first: &first) { try boolean(value.isApproximate) }
        }
    }

    private func writeStatistics(_ value: ExportStatistics) throws {
        try object { first in
            try field("documentCount", first: &first) { try integer(value.documentCount) }
            try field("epubDocumentCount", first: &first) { try integer(value.epubDocumentCount) }
            try field("pdfDocumentCount", first: &first) { try integer(value.pdfDocumentCount) }
            try field("recordCount", first: &first) { try integer(value.recordCount) }
            try field("epubAnnotationCount", first: &first) { try integer(value.epubAnnotationCount) }
            try field("pdfHighlightCount", first: &first) { try integer(value.pdfHighlightCount) }
            try field("highlightCount", first: &first) { try integer(value.highlightCount) }
            try field("noteCount", first: &first) { try integer(value.noteCount) }
            try field("historicalEPUBAnnotationCount", first: &first) { try integer(value.historicalEPUBAnnotationCount) }
            try field("unmappedEPUBAnnotationCount", first: &first) { try integer(value.unmappedEPUBAnnotationCount) }
        }
    }

    private func writeSourceTotals(_ value: ExportSourceTotals) throws {
        try object { first in
            try field("epubDocumentCount", first: &first) { try integer(value.epubDocumentCount) }
            try field("epubAnnotationCount", first: &first) { try integer(value.epubAnnotationCount) }
            try field("pdfAttemptedDocumentCount", first: &first) { try integer(value.pdfAttemptedDocumentCount) }
            try field("pdfSucceededDocumentCount", first: &first) { try integer(value.pdfSucceededDocumentCount) }
            try field("pdfFailedDocumentCount", first: &first) { try integer(value.pdfFailedDocumentCount) }
            try field("pdfHighlightCount", first: &first) { try integer(value.pdfHighlightCount) }
        }
    }

    private func writeWarning(_ value: ExportWarning) throws {
        try object { first in
            switch value {
            case .pdfUnavailable:
                try field("code", first: &first) { try string("pdfUnavailable") }
            case let .pdfFailure(failure):
                try field("code", first: &first) { try string("pdfFailure") }
                try field("pdfSource", first: &first) { try writePDFSource(failure.source) }
                try field("pdfFailure", first: &first) { try writePDFFailure(failure.reason) }
            }
        }
    }

    private func writePDFFailure(_ value: PDFHighlightServiceFailureReason) throws {
        try object { first in
            switch value {
            case .timeout:
                try field("kind", first: &first) { try string("timeout") }
            case .internalFailure:
                try field("kind", first: &first) { try string("internalFailure") }
            case let .worker(error):
                try field("kind", first: &first) { try string("worker") }
                try field("workerError", first: &first) { try writeWorkerError(error) }
            }
        }
    }

    private func writeWorkerError(_ value: PDFWorkerClientError) throws {
        try object { first in
            let code: String
            switch value {
            case .launchFailed: code = "launchFailed"
            case .timedOut: code = "timedOut"
            case .stdoutLimitExceeded: code = "stdoutLimitExceeded"
            case .stderrLimitExceeded: code = "stderrLimitExceeded"
            case .pipeReadFailed: code = "pipeReadFailed"
            case .nonzeroExit: code = "nonzeroExit"
            case .signalTerminated: code = "signalTerminated"
            case .malformedResponse: code = "malformedResponse"
            case .workerFailure: code = "workerFailure"
            }
            try field("code", first: &first) { try string(code) }
            switch value {
            case let .stdoutLimitExceeded(bytes), let .stderrLimitExceeded(bytes):
                try field("capturedBytes", first: &first) { try integer(bytes) }
            case let .nonzeroExit(status):
                try field("exitStatus", first: &first) { try integer(status) }
            case let .signalTerminated(signal):
                try field("signal", first: &first) { try integer(signal) }
            case let .workerFailure(workerCode):
                try field("workerCode", first: &first) { try string(workerCode.rawValue) }
            case .launchFailed, .timedOut, .pipeReadFailed, .malformedResponse:
                break
            }
        }
    }

    private func object(_ body: (inout Bool) throws -> Void) throws {
        try appendASCII("{")
        var first = true
        try body(&first)
        try appendASCII("}")
    }

    private func field(_ name: String, first: inout Bool, _ writeValue: () throws -> Void) throws {
        if first { first = false } else { try appendASCII(",") }
        try string(name)
        try appendASCII(":")
        try writeValue()
    }

    private func optionalField<Value>(
        _ name: String,
        value: Value?,
        first: inout Bool,
        write: (Value) throws -> Void
    ) throws {
        guard let value else { return }
        try field(name, first: &first) { try write(value) }
    }

    private func array<Value>(_ values: [Value], _ write: (Value) throws -> Void) throws {
        try appendASCII("[")
        for (index, value) in values.enumerated() {
            if index > 0 { try appendASCII(",") }
            try write(value)
        }
        try appendASCII("]")
    }

    private func nullableDouble(_ value: Double?) throws {
        if let value { try double(value) } else { try appendASCII("null") }
    }

    private func integer<IntegerValue: BinaryInteger>(_ value: IntegerValue) throws {
        try appendASCII(String(value))
    }

    private func double(_ value: Double) throws {
        guard value.isFinite else { throw StreamingJSONError.nonFiniteNumber }
        try appendASCII(String(value))
    }

    private func boolean(_ value: Bool) throws {
        try appendASCII(value ? "true" : "false")
    }

    private func string(_ value: String) throws {
        try appendASCII("\"")
        for byte in value.utf8 {
            switch byte {
            case 0x22: try appendASCII("\\\"")
            case 0x5c: try appendASCII("\\\\")
            case 0x08: try appendASCII("\\b")
            case 0x0c: try appendASCII("\\f")
            case 0x0a: try appendASCII("\\n")
            case 0x0d: try appendASCII("\\r")
            case 0x09: try appendASCII("\\t")
            case 0x00...0x1f:
                let hex = Array("0123456789abcdef".utf8)
                try appendASCII("\\u00")
                try appendByte(hex[Int(byte >> 4)])
                try appendByte(hex[Int(byte & 0x0f)])
            default:
                try appendByte(byte)
            }
        }
        try appendASCII("\"")
    }

    private func base64(_ data: Data) throws {
        try appendASCII("\"")
        try data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index + 3 <= bytes.count {
                let a = bytes[index]
                let b = bytes[index + 1]
                let c = bytes[index + 2]
                try appendByte(Self.base64Alphabet[Int(a >> 2)])
                try appendByte(Self.base64Alphabet[Int(((a & 0x03) << 4) | (b >> 4))])
                try appendByte(Self.base64Alphabet[Int(((b & 0x0f) << 2) | (c >> 6))])
                try appendByte(Self.base64Alphabet[Int(c & 0x3f)])
                index += 3
            }
            let remaining = bytes.count - index
            if remaining == 1 {
                let a = bytes[index]
                try appendByte(Self.base64Alphabet[Int(a >> 2)])
                try appendByte(Self.base64Alphabet[Int((a & 0x03) << 4)])
                try appendASCII("==")
            } else if remaining == 2 {
                let a = bytes[index]
                let b = bytes[index + 1]
                try appendByte(Self.base64Alphabet[Int(a >> 2)])
                try appendByte(Self.base64Alphabet[Int(((a & 0x03) << 4) | (b >> 4))])
                try appendByte(Self.base64Alphabet[Int((b & 0x0f) << 2)])
                try appendASCII("=")
            }
        }
        try appendASCII("\"")
    }

    private func appendASCII(_ value: String) throws {
        for byte in value.utf8 { try appendByte(byte) }
    }

    private func appendByte(_ byte: UInt8) throws {
        if buffer.count == ExportFileWriter.maximumChunkBytes { try flush() }
        buffer.append(byte)
    }

    private func flush() throws {
        guard buffer.isEmpty == false else { return }
        observeBufferedBytes?(buffer.count)
        try sink(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}

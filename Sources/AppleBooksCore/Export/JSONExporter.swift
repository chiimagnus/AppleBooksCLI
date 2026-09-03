import CoreGraphics
import Foundation

public enum JSONExporter {
    static let schemaVersion = 2

    public static func render(_ bundle: ExportBundle, exportedAt: Date) throws -> Data {
        let mapper = JSONExportMapper()
        return try encoder().encode(mapper.root(bundle: bundle, exportedAt: exportedAt))
    }

    public static func renderDocument(_ group: ExportGroup, from bundle: ExportBundle, exportedAt: Date) throws -> Data {
        let mapper = JSONExportMapper()
        return try encoder().encode(
            JSONDocumentRootDTO(
                schemaVersion: schemaVersion,
                exportedAt: mapper.date(exportedAt),
                options: mapper.options(bundle.options),
                group: mapper.group(group)
            )
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

private struct JSONExportMapper {
    private let formatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        self.formatter = formatter
    }

    func root(bundle: ExportBundle, exportedAt: Date) -> JSONExportRootDTO {
        JSONExportRootDTO(
            schemaVersion: JSONExporter.schemaVersion,
            exportedAt: date(exportedAt),
            options: options(bundle.options),
            statistics: JSONStatisticsDTO(bundle.statistics),
            sourceTotals: JSONSourceTotalsDTO(bundle.sourceTotals),
            warnings: bundle.warnings.map(warning),
            groups: bundle.groups.map(group)
        )
    }

    func date(_ value: Date) -> String {
        formatter.string(from: value)
    }

    func date(_ value: Date?) -> String? {
        value.map(date)
    }

    func options(_ value: ExportOptions) -> JSONOptionsDTO {
        JSONOptionsDTO(
            source: value.source.rawValue,
            bookSelectors: value.bookSelectors.map { selector in
                switch selector {
                case let .assetID(assetID):
                    JSONBookSelectorDTO(kind: "assetID", value: assetID)
                case let .localPK(localPK):
                    JSONBookSelectorDTO(kind: "localPK", value: String(localPK))
                case let .pdfFile(url):
                    JSONBookSelectorDTO(kind: "pdfFile", value: url.path)
                }
            },
            kinds: value.kinds.map(\.rawValue).sorted(),
            colors: value.colors?.map(\.rawValue).sorted(),
            underline: value.underline,
            order: value.order.rawValue,
            skipFirstPerBook: value.skipFirstPerBook,
            grouping: value.grouping.rawValue,
            includeEPUBMetadata: value.includeEPUBMetadata,
            cover: value.cover.rawValue,
            completeNotes: value.completeNotes
        )
    }

    func group(_ value: ExportGroup) -> JSONGroupDTO {
        JSONGroupDTO(
            source: groupSource(value.source),
            epubMetadata: value.epubMetadata.map(metadata),
            epubCover: value.epubCover.map(cover),
            records: value.records.map(record)
        )
    }

    private func groupSource(_ value: ExportGroupSource) -> JSONGroupSourceDTO {
        switch value {
        case let .epubCurrent(book):
            JSONGroupSourceDTO(kind: "epubCurrent", book: JSONBookDTO(book))
        case let .epubHistorical(assetID, metadata):
            JSONGroupSourceDTO(
                kind: "epubHistorical",
                assetID: assetID,
                historicalMetadata: JSONHistoricalMetadataDTO(metadata)
            )
        case let .epubUnmapped(assetID):
            JSONGroupSourceDTO(kind: "epubUnmapped", assetID: assetID)
        case let .pdf(source):
            JSONGroupSourceDTO(kind: "pdf", pdfSource: pdfSource(source))
        }
    }

    private func record(_ value: ExportRecord) -> JSONRecordDTO {
        let presentation = JSONPresentationDTO(
            kind: value.presentationKind.rawValue,
            color: value.presentationColor?.rawValue,
            underline: value.isUnderline
        )
        switch value.payload {
        case let .epub(enriched):
            return JSONRecordDTO(
                source: "epub",
                presentation: presentation,
                annotation: annotation(enriched.annotation),
                pdfHighlight: nil
            )
        case let .pdf(_, highlight):
            return JSONRecordDTO(
                source: "pdf",
                presentation: presentation,
                annotation: nil,
                pdfHighlight: pdfHighlight(highlight)
            )
        }
    }

    private func annotation(_ value: Annotation) -> JSONAnnotationDTO {
        JSONAnnotationDTO(
            localPK: value.localPK,
            uuid: value.uuid,
            rawAssetID: value.rawAssetID,
            isDeleted: value.isDeleted,
            isUnderline: value.isUnderline,
            style: value.style,
            type: value.type,
            createdAt: date(value.createdAt),
            modifiedAt: date(value.modifiedAt),
            representativeText: value.representativeText,
            selectedText: value.selectedText,
            note: value.note,
            appleBooksURL: value.appleBooksURL,
            location: value.location.map(JSONLocationDTO.init),
            chapterHint: value.chapterHint,
            physicalLocation: value.physicalLocation,
            rangeStart: value.rangeStart,
            rangeEnd: value.rangeEnd
        )
    }

    private func metadata(_ value: EPUBMetadata) -> JSONEPUBMetadataDTO {
        JSONEPUBMetadataDTO(
            title: value.title,
            creator: value.creator,
            identifiers: value.identifiers,
            isbn: value.isbn,
            language: value.language,
            publisher: value.publisher,
            publicationDate: value.publicationDate,
            rights: value.rights,
            subjects: value.subjects,
            coverItemID: value.coverItemID
        )
    }

    private func cover(_ value: EPUBCover) -> JSONEPUBCoverDTO {
        JSONEPUBCoverDTO(
            dataBase64: value.data.base64EncodedString(),
            declaredMediaType: value.declaredMediaType,
            detectedMediaType: value.detectedMediaType,
            mediaType: value.mediaType,
            source: value.source.rawValue
        )
    }

    private func pdfSource(_ value: PDFSource) -> JSONPDFSourceDTO {
        JSONPDFSourceDTO(
            filePath: value.fileURL.path,
            displayTitle: value.displayTitle,
            book: value.book.map(JSONBookDTO.init)
        )
    }

    private func pdfHighlight(_ value: PDFHighlight) -> JSONPDFHighlightDTO {
        JSONPDFHighlightDTO(
            page: value.page,
            traversalIndex: value.traversalIndex,
            bounds: JSONRectDTO(value.bounds),
            quadrilateralPoints: value.quadrilateralPoints.map(JSONPointDTO.init),
            note: value.note,
            pdfKitRGBA: value.pdfKitRGBA,
            presentationColor: value.presentationColor.map(JSONPDFColorMatchDTO.init),
            modifiedAt: date(value.modifiedAt),
            text: value.text,
            textSource: value.textSource?.rawValue,
            textIsApproximate: value.textIsApproximate,
            textUnavailableReason: value.textUnavailableReason?.rawValue
        )
    }

    private func warning(_ value: ExportWarning) -> JSONWarningDTO {
        switch value {
        case let .epubContentUnavailable(bookLocalPK):
            return JSONWarningDTO(code: "epubContentUnavailable", bookLocalPK: bookLocalPK)
        case let .epubMetadataUnavailable(bookLocalPK):
            return JSONWarningDTO(code: "epubMetadataUnavailable", bookLocalPK: bookLocalPK)
        case let .epubCoverUnavailable(bookLocalPK):
            return JSONWarningDTO(code: "epubCoverUnavailable", bookLocalPK: bookLocalPK)
        case let .pdfFailure(failure):
            return JSONWarningDTO(
                code: "pdfFailure",
                pdfSource: pdfSource(failure.source),
                pdfFailure: pdfFailure(failure.reason)
            )
        }
    }

    private func pdfFailure(_ value: PDFHighlightServiceFailureReason) -> JSONPDFFailureDTO {
        switch value {
        case .timeout:
            JSONPDFFailureDTO(kind: "timeout")
        case .internalFailure:
            JSONPDFFailureDTO(kind: "internalFailure")
        case let .worker(error):
            JSONPDFFailureDTO(kind: "worker", workerError: JSONWorkerErrorDTO(error))
        }
    }
}

private struct JSONExportRootDTO: Encodable {
    let schemaVersion: Int
    let exportedAt: String
    let options: JSONOptionsDTO
    let statistics: JSONStatisticsDTO
    let sourceTotals: JSONSourceTotalsDTO
    let warnings: [JSONWarningDTO]
    let groups: [JSONGroupDTO]
}

private struct JSONDocumentRootDTO: Encodable {
    let schemaVersion: Int
    let exportedAt: String
    let options: JSONOptionsDTO
    let group: JSONGroupDTO
}

private struct JSONOptionsDTO: Encodable {
    let source: String
    let bookSelectors: [JSONBookSelectorDTO]
    let kinds: [String]
    let colors: [String]?
    let underline: Bool?
    let order: String
    let skipFirstPerBook: Int
    let grouping: String
    let includeEPUBMetadata: Bool
    let cover: String
    let completeNotes: Bool
}

private struct JSONBookSelectorDTO: Encodable {
    let kind: String
    let value: String
}

private struct JSONGroupDTO: Encodable {
    let source: JSONGroupSourceDTO
    let epubMetadata: JSONEPUBMetadataDTO?
    let epubCover: JSONEPUBCoverDTO?
    let records: [JSONRecordDTO]
}

private struct JSONGroupSourceDTO: Encodable {
    let kind: String
    let assetID: String?
    let book: JSONBookDTO?
    let historicalMetadata: JSONHistoricalMetadataDTO?
    let pdfSource: JSONPDFSourceDTO?

    init(
        kind: String,
        assetID: String? = nil,
        book: JSONBookDTO? = nil,
        historicalMetadata: JSONHistoricalMetadataDTO? = nil,
        pdfSource: JSONPDFSourceDTO? = nil
    ) {
        self.kind = kind
        self.assetID = assetID
        self.book = book
        self.historicalMetadata = historicalMetadata
        self.pdfSource = pdfSource
    }
}

private struct JSONRecordDTO: Encodable {
    let source: String
    let presentation: JSONPresentationDTO
    let annotation: JSONAnnotationDTO?
    let pdfHighlight: JSONPDFHighlightDTO?
}

private struct JSONPresentationDTO: Encodable {
    let kind: String
    let color: String?
    let underline: Bool
}

private struct JSONAnnotationDTO: Encodable {
    let localPK: Int64
    let uuid: String?
    let rawAssetID: String?
    let isDeleted: Bool?
    let isUnderline: Bool?
    let style: Int64?
    let type: Int64?
    let createdAt: String?
    let modifiedAt: String?
    let representativeText: String?
    let selectedText: String?
    let note: String?
    let appleBooksURL: String?
    let location: JSONLocationDTO?
    let chapterHint: String?
    let physicalLocation: Int64?
    let rangeStart: Int64?
    let rangeEnd: Int64?
}

private struct JSONLocationDTO: Encodable {
    let rawCFI: String
    let chapterID: String?
    let characterRange: JSONCharacterRangeDTO?

    init(_ value: Location) {
        rawCFI = value.rawCFI
        chapterID = value.chapterID
        characterRange = value.characterRange.map(JSONCharacterRangeDTO.init)
    }
}

private struct JSONCharacterRangeDTO: Encodable {
    let start: Int
    let end: Int

    init(_ value: Location.CharacterRange) {
        start = value.start
        end = value.end
    }
}

private struct JSONBookDTO: Encodable {
    let localPK: Int64
    let assetID: String?
    let title: String?
    let author: String?
    let description: String?
    let epubID: String?
    let genre: String?
    let genresRawBase64: String?
    let comments: String?
    let language: String?
    let year: Int64?
    let contentType: Int64?
    let pageCount: Int64?
    let path: String?
    let fileSize: Int64?
    let coverURL: String?
    let isFinished: Bool?
    let readingProgressRaw: Double?
    let durationRawMilliseconds: Double?
    let creationDate: String?
    let modificationDate: String?
    let finishedDate: String?
    let lastOpenDate: String?
    let purchaseDate: String?
    let releaseDate: String?
    let isExplicit: Bool?
    let isLocked: Bool?
    let isEphemeral: Bool?
    let isHidden: Bool?
    let isSample: Bool?
    let isStoreAudiobook: Bool?
    let rating: Double?

    init(_ value: Book) {
        let mapper = JSONExportMapper()
        localPK = value.localPK
        assetID = value.assetID
        title = value.title
        author = value.author
        description = value.description
        epubID = value.epubID
        genre = value.genre
        genresRawBase64 = value.genresRaw?.base64EncodedString()
        comments = value.comments
        language = value.language
        year = value.year
        contentType = value.contentType
        pageCount = value.pageCount
        path = value.path
        fileSize = value.fileSize
        coverURL = value.coverURL
        isFinished = value.isFinished
        readingProgressRaw = value.readingProgressRaw
        durationRawMilliseconds = value.durationRawMilliseconds
        creationDate = mapper.date(value.creationDate)
        modificationDate = mapper.date(value.modificationDate)
        finishedDate = mapper.date(value.finishedDate)
        lastOpenDate = mapper.date(value.lastOpenDate)
        purchaseDate = mapper.date(value.purchaseDate)
        releaseDate = mapper.date(value.releaseDate)
        isExplicit = value.isExplicit
        isLocked = value.isLocked
        isEphemeral = value.isEphemeral
        isHidden = value.isHidden
        isSample = value.isSample
        isStoreAudiobook = value.isStoreAudiobook
        rating = value.rating
    }
}

private struct JSONHistoricalMetadataDTO: Encodable {
    let title: String
    let author: String

    init(_ value: HistoricalBookMetadata) {
        title = value.title
        author = value.author
    }
}

private struct JSONEPUBMetadataDTO: Encodable {
    let title: String?
    let creator: String?
    let identifiers: [String]
    let isbn: String?
    let language: String?
    let publisher: String?
    let publicationDate: String?
    let rights: String?
    let subjects: [String]
    let coverItemID: String?
}

private struct JSONEPUBCoverDTO: Encodable {
    let dataBase64: String
    let declaredMediaType: String?
    let detectedMediaType: String?
    let mediaType: String?
    let source: String
}

private struct JSONPDFSourceDTO: Encodable {
    let filePath: String
    let displayTitle: String
    let book: JSONBookDTO?
}

private struct JSONPDFHighlightDTO: Encodable {
    let page: Int
    let traversalIndex: Int
    let bounds: JSONRectDTO
    let quadrilateralPoints: [JSONPointDTO]
    let note: String?
    let pdfKitRGBA: [Double]?
    let presentationColor: JSONPDFColorMatchDTO?
    let modifiedAt: String?
    let text: String?
    let textSource: String?
    let textIsApproximate: Bool
    let textUnavailableReason: String?
}

private struct JSONRectDTO: Encodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ value: CGRect) {
        x = Double(value.origin.x)
        y = Double(value.origin.y)
        width = Double(value.size.width)
        height = Double(value.size.height)
    }
}

private struct JSONPointDTO: Encodable {
    let x: Double
    let y: Double

    init(_ value: CGPoint) {
        x = Double(value.x)
        y = Double(value.y)
    }
}

private struct JSONPDFColorMatchDTO: Encodable {
    let color: String
    let distance: Double
    let isApproximate: Bool

    init(_ value: PDFColorMatch) {
        color = value.color.rawValue
        distance = value.distance
        isApproximate = value.isApproximate
    }
}

private struct JSONStatisticsDTO: Encodable {
    let documentCount: Int
    let epubDocumentCount: Int
    let pdfDocumentCount: Int
    let recordCount: Int
    let epubAnnotationCount: Int
    let pdfHighlightCount: Int
    let highlightCount: Int
    let noteCount: Int
    let bookmarkCount: Int
    let historicalEPUBAnnotationCount: Int
    let unmappedEPUBAnnotationCount: Int

    init(_ value: ExportStatistics) {
        documentCount = value.documentCount
        epubDocumentCount = value.epubDocumentCount
        pdfDocumentCount = value.pdfDocumentCount
        recordCount = value.recordCount
        epubAnnotationCount = value.epubAnnotationCount
        pdfHighlightCount = value.pdfHighlightCount
        highlightCount = value.highlightCount
        noteCount = value.noteCount
        bookmarkCount = value.bookmarkCount
        historicalEPUBAnnotationCount = value.historicalEPUBAnnotationCount
        unmappedEPUBAnnotationCount = value.unmappedEPUBAnnotationCount
    }
}

private struct JSONSourceTotalsDTO: Encodable {
    let epubDocumentCount: Int
    let epubAnnotationCount: Int
    let pdfAttemptedDocumentCount: Int
    let pdfSucceededDocumentCount: Int
    let pdfFailedDocumentCount: Int
    let pdfHighlightCount: Int

    init(_ value: ExportSourceTotals) {
        epubDocumentCount = value.epubDocumentCount
        epubAnnotationCount = value.epubAnnotationCount
        pdfAttemptedDocumentCount = value.pdfAttemptedDocumentCount
        pdfSucceededDocumentCount = value.pdfSucceededDocumentCount
        pdfFailedDocumentCount = value.pdfFailedDocumentCount
        pdfHighlightCount = value.pdfHighlightCount
    }
}

private struct JSONWarningDTO: Encodable {
    let code: String
    let bookLocalPK: Int64?
    let pdfSource: JSONPDFSourceDTO?
    let pdfFailure: JSONPDFFailureDTO?

    init(
        code: String,
        bookLocalPK: Int64? = nil,
        pdfSource: JSONPDFSourceDTO? = nil,
        pdfFailure: JSONPDFFailureDTO? = nil
    ) {
        self.code = code
        self.bookLocalPK = bookLocalPK
        self.pdfSource = pdfSource
        self.pdfFailure = pdfFailure
    }
}

private struct JSONPDFFailureDTO: Encodable {
    let kind: String
    let workerError: JSONWorkerErrorDTO?

    init(kind: String, workerError: JSONWorkerErrorDTO? = nil) {
        self.kind = kind
        self.workerError = workerError
    }
}

private struct JSONWorkerErrorDTO: Encodable {
    let code: String
    let capturedBytes: Int?
    let exitStatus: Int32?
    let signal: Int32?
    let workerCode: String?

    init(_ value: PDFWorkerClientError) {
        switch value {
        case .launchFailed:
            code = "launchFailed"
            capturedBytes = nil
            exitStatus = nil
            signal = nil
            workerCode = nil
        case .timedOut:
            code = "timedOut"
            capturedBytes = nil
            exitStatus = nil
            signal = nil
            workerCode = nil
        case let .stdoutLimitExceeded(bytes):
            code = "stdoutLimitExceeded"
            capturedBytes = bytes
            exitStatus = nil
            signal = nil
            workerCode = nil
        case let .stderrLimitExceeded(bytes):
            code = "stderrLimitExceeded"
            capturedBytes = bytes
            exitStatus = nil
            signal = nil
            workerCode = nil
        case .pipeReadFailed:
            code = "pipeReadFailed"
            capturedBytes = nil
            exitStatus = nil
            signal = nil
            workerCode = nil
        case let .nonzeroExit(status):
            code = "nonzeroExit"
            capturedBytes = nil
            exitStatus = status
            signal = nil
            workerCode = nil
        case let .signalTerminated(signal):
            code = "signalTerminated"
            capturedBytes = nil
            exitStatus = nil
            self.signal = signal
            workerCode = nil
        case .malformedResponse:
            code = "malformedResponse"
            capturedBytes = nil
            exitStatus = nil
            signal = nil
            workerCode = nil
        case let .workerFailure(workerCode):
            code = "workerFailure"
            capturedBytes = nil
            exitStatus = nil
            signal = nil
            self.workerCode = workerCode.rawValue
        }
    }
}

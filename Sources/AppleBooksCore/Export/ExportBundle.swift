import Foundation

public enum ExportGroupSource: Equatable, Sendable {
    case epubCurrent(Book)
    case epubHistorical(assetID: String?, metadata: HistoricalBookMetadata)
    case epubUnmapped(assetID: String?)
    case pdf(PDFSource)
}

public struct ExportGroup: Equatable, Sendable {
    public let source: ExportGroupSource
    public let records: [ExportRecord]
    public let epubMetadata: EPUBMetadata?
    public let epubCover: EPUBCover?

    init(
        source: ExportGroupSource,
        records: [ExportRecord],
        epubMetadata: EPUBMetadata? = nil,
        epubCover: EPUBCover? = nil
    ) {
        self.source = source
        self.records = records
        self.epubMetadata = epubMetadata
        self.epubCover = epubCover
    }
}

public enum ExportWarning: Equatable, Sendable {
    case epubContentUnavailable(bookLocalPK: Int64)
    case epubMetadataUnavailable(bookLocalPK: Int64)
    case epubCoverUnavailable(bookLocalPK: Int64)
    case pdfFailure(PDFHighlightServiceFailure)
}

public struct ExportSourceTotals: Equatable, Sendable {
    public let epubDocumentCount: Int
    public let epubAnnotationCount: Int
    public let pdfAttemptedDocumentCount: Int
    public let pdfSucceededDocumentCount: Int
    public let pdfFailedDocumentCount: Int
    public let pdfHighlightCount: Int
}

public struct ExportStatistics: Equatable, Sendable {
    public let documentCount: Int
    public let epubDocumentCount: Int
    public let pdfDocumentCount: Int
    public let recordCount: Int
    public let epubAnnotationCount: Int
    public let pdfHighlightCount: Int
    public let highlightCount: Int
    public let noteCount: Int
    public let bookmarkCount: Int
    public let historicalEPUBAnnotationCount: Int
    public let unmappedEPUBAnnotationCount: Int
}

public struct ExportBundle: Equatable, Sendable {
    public let options: ExportOptions
    public let groups: [ExportGroup]
    public let warnings: [ExportWarning]
    public let statistics: ExportStatistics
    public let sourceTotals: ExportSourceTotals
}

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

    init(source: ExportGroupSource, records: [ExportRecord]) {
        self.source = source
        self.records = records
    }
}

public enum ExportWarning: Equatable, Sendable {
    case pdfUnavailable
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
    public let historicalEPUBAnnotationCount: Int
    public let unmappedEPUBAnnotationCount: Int
}

public struct ExportBundle: Equatable, Sendable {
    public let options: ExportOptions
    public let groups: [ExportGroup]
    public let warnings: [ExportWarning]
    public let statistics: ExportStatistics
    public let sourceTotals: ExportSourceTotals

    public var complete: Bool {
        sourceTotals.pdfFailedDocumentCount == 0 && !warnings.contains(.pdfUnavailable)
    }
}

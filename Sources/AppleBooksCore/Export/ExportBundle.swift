import Foundation

public enum ExportGroupSource: Equatable, Sendable {
    case epubCurrent(Book)
    case epubHistorical(assetID: String?, metadata: HistoricalBookMetadata)
    case epubUnmapped(assetID: String?)
}

public struct ExportGroup: Equatable, Sendable {
    public let source: ExportGroupSource
    public let records: [ExportRecord]
    let documentIdentity: ExportDocumentIdentity?

    init(
        source: ExportGroupSource,
        records: [ExportRecord],
        documentIdentity: ExportDocumentIdentity? = nil
    ) {
        self.source = source
        self.records = records
        self.documentIdentity = documentIdentity
    }
}

public struct ExportSourceTotals: Equatable, Sendable {
    public let epubDocumentCount: Int
    public let epubAnnotationCount: Int
}

public struct ExportStatistics: Equatable, Sendable {
    public let documentCount: Int
    public let epubDocumentCount: Int
    public let recordCount: Int
    public let epubAnnotationCount: Int
    public let highlightCount: Int
    public let noteCount: Int
    public let historicalEPUBAnnotationCount: Int
    public let unmappedEPUBAnnotationCount: Int
}

public struct ExportBundle: Equatable, Sendable {
    public let options: ExportOptions
    public let groups: [ExportGroup]
    public let statistics: ExportStatistics
    public let sourceTotals: ExportSourceTotals
}

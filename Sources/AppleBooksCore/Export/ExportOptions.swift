import Foundation

public enum ExportOptionsError: Error, Equatable, Sendable {
    case emptyColors
    case invalidBookSelector
    case conflictingOptions
}

public enum ExportSourceScope: String, Equatable, Hashable, Sendable {
    case epub
    case pdf
    case all
}

public enum ExportPresentationColor: String, Equatable, Hashable, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple
}

public enum ExportOrder: String, Equatable, Sendable {
    case reading
}

public enum ExportFileGrouping: String, Equatable, Sendable {
    case single
    case perBook
}

public enum ExportBookSelector: Equatable, Hashable, Sendable {
    case assetID(String)
    case localPK(Int64)
    case pdfSourceID(String)
}

public struct ExportOptions: Equatable, Sendable {
    public let source: ExportSourceScope
    public let bookSelectors: [ExportBookSelector]
    public let hasHighlight: Bool?
    public let hasNote: Bool?
    public let colors: Set<ExportPresentationColor>?
    public let underline: Bool?
    public let order: ExportOrder
    public let grouping: ExportFileGrouping

    public init(
        source: ExportSourceScope = .all,
        bookSelectors: [ExportBookSelector] = [],
        hasHighlight: Bool? = nil,
        hasNote: Bool? = nil,
        colors: Set<ExportPresentationColor>? = nil,
        underline: Bool? = nil,
        order: ExportOrder = .reading,
        grouping: ExportFileGrouping = .single
    ) throws {
        if let colors {
            guard colors.isEmpty == false else { throw ExportOptionsError.emptyColors }
        }
        for selector in bookSelectors {
            switch selector {
            case let .assetID(value):
                guard value.isEmpty == false else { throw ExportOptionsError.invalidBookSelector }
            case .localPK:
                break
            case let .pdfSourceID(value):
                guard (try? PDFSourceID.parse(value)) != nil else {
                    throw ExportOptionsError.invalidBookSelector
                }
            }
        }
        if !bookSelectors.isEmpty, source != .all {
            throw ExportOptionsError.conflictingOptions
        }
        self.source = source
        self.bookSelectors = bookSelectors
        self.hasHighlight = hasHighlight
        self.hasNote = hasNote
        self.colors = colors
        self.underline = underline
        self.order = order
        self.grouping = grouping
    }
}

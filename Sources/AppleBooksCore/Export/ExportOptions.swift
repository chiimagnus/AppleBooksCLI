import Foundation

public enum ExportOptionsError: Error, Equatable, Sendable {
    case emptyColors
    case invalidBookSelector
}

public enum ExportPresentationColor: String, Equatable, Hashable, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple
}

public enum ExportFileGrouping: String, Equatable, Sendable {
    case single
    case perDocument = "per-document"
}

public enum ExportBookSelector: Equatable, Hashable, Sendable {
    case assetID(String)
    case localPK(Int64)
}

public struct ExportOptions: Equatable, Sendable {
    public let bookSelectors: [ExportBookSelector]
    public let hasHighlight: Bool?
    public let hasNote: Bool?
    public let colors: Set<ExportPresentationColor>?
    public let underline: Bool?
    public let grouping: ExportFileGrouping

    public init(
        bookSelectors: [ExportBookSelector] = [],
        hasHighlight: Bool? = nil,
        hasNote: Bool? = nil,
        colors: Set<ExportPresentationColor>? = nil,
        underline: Bool? = nil,
        grouping: ExportFileGrouping = .single
    ) throws {
        if let colors {
            guard !colors.isEmpty else { throw ExportOptionsError.emptyColors }
        }
        for selector in bookSelectors {
            if case let .assetID(value) = selector {
                guard !value.isEmpty else { throw ExportOptionsError.invalidBookSelector }
            }
        }
        self.bookSelectors = bookSelectors
        self.hasHighlight = hasHighlight
        self.hasNote = hasNote
        self.colors = colors
        self.underline = underline
        self.grouping = grouping
    }
}

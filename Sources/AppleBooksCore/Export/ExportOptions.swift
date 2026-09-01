import Foundation

public enum ExportOptionsError: Error, Equatable, Sendable {
    case emptyKinds
    case emptyColors
    case negativeSkip
    case invalidBookSelector
}

public enum ExportSourceScope: String, Equatable, Hashable, Sendable {
    case epub
    case pdf
    case all
}

public enum ExportPresentationKind: String, Equatable, Hashable, Sendable {
    case highlight
    case note
    case bookmark
}

public enum ExportPresentationColor: String, Equatable, Hashable, Sendable {
    case green
    case blue
    case yellow
    case pink
    case purple
}

public enum ExportOrder: String, Equatable, Sendable {
    case source
    case reading
}

public enum ExportFileGrouping: String, Equatable, Sendable {
    case single
    case perBook
}

public enum ExportCoverMode: String, Equatable, Sendable {
    case none
    case inline
    case file
}

public enum ExportBookSelector: Equatable, Hashable, Sendable {
    case assetID(String)
    case pdfFile(URL)
}

public struct ExportOptions: Equatable, Sendable {
    public let source: ExportSourceScope
    public let bookSelectors: [ExportBookSelector]
    public let kinds: Set<ExportPresentationKind>
    public let colors: Set<ExportPresentationColor>?
    public let underline: Bool?
    public let order: ExportOrder
    public let skipFirstPerBook: Int
    public let grouping: ExportFileGrouping
    public let includeEPUBMetadata: Bool
    public let cover: ExportCoverMode

    public init(
        source: ExportSourceScope = .epub,
        bookSelectors: [ExportBookSelector] = [],
        kinds: Set<ExportPresentationKind> = [.highlight, .note],
        colors: Set<ExportPresentationColor>? = nil,
        underline: Bool? = nil,
        order: ExportOrder = .source,
        skipFirstPerBook: Int = 0,
        grouping: ExportFileGrouping = .single,
        includeEPUBMetadata: Bool = false,
        cover: ExportCoverMode = .none
    ) throws {
        guard kinds.isEmpty == false else { throw ExportOptionsError.emptyKinds }
        if let colors {
            guard colors.isEmpty == false else { throw ExportOptionsError.emptyColors }
        }
        guard skipFirstPerBook >= 0 else { throw ExportOptionsError.negativeSkip }
        for selector in bookSelectors {
            switch selector {
            case let .assetID(value):
                guard value.isEmpty == false else { throw ExportOptionsError.invalidBookSelector }
            case let .pdfFile(url):
                guard url.isFileURL,
                      url.path.hasPrefix("/"),
                      url.standardizedFileURL.path == url.path else {
                    throw ExportOptionsError.invalidBookSelector
                }
            }
        }

        self.source = source
        self.bookSelectors = bookSelectors
        self.kinds = kinds
        self.colors = colors
        self.underline = underline
        self.order = order
        self.skipFirstPerBook = skipFirstPerBook
        self.grouping = grouping
        self.includeEPUBMetadata = includeEPUBMetadata
        self.cover = cover
    }
}

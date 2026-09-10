import Foundation

enum ResolvedExportSourceKey: Hashable {
    case currentBook(Int64)
    case epubAsset(String)
    case pdfSlot(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.currentBook(left), .currentBook(right)): left == right
        case let (.epubAsset(left), .epubAsset(right)), let (.pdfSlot(left), .pdfSlot(right)):
            left.utf8.elementsEqual(right.utf8)
        default: false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case let .currentBook(localPK):
            hasher.combine(0)
            hasher.combine(localPK)
        case let .epubAsset(rawValue):
            hasher.combine(1)
            for byte in rawValue.utf8 { hasher.combine(byte) }
        case let .pdfSlot(rawValue):
            hasher.combine(2)
            for byte in rawValue.utf8 { hasher.combine(byte) }
        }
    }
}

struct ResolvedExportSource {
    let key: ResolvedExportSourceKey
    let epubAssetID: String?
    let pdfSource: PDFSource?
    let requiresHistoricalEvidence: Bool
}

struct ExportSourceResolver {
    let bookQueries: BookQueries
    let pdfSourceResolver: PDFSourceResolver

    func resolve(_ selectors: [ExportBookSelector]) throws -> [ResolvedExportSource] {
        var seen = Set<ResolvedExportSourceKey>()
        var sources: [ResolvedExportSource] = []
        for selector in selectors {
            let resolved: ResolvedExportSource
            switch selector {
            case let .assetID(assetID):
                if let book = try bookQueries.getUniqueByAssetID(assetID) {
                    resolved = try resolve(book)
                } else {
                    resolved = ResolvedExportSource(
                        key: .epubAsset(assetID), epubAssetID: assetID,
                        pdfSource: nil, requiresHistoricalEvidence: true
                    )
                }
            case let .localPK(localPK):
                guard let book = try bookQueries.getByLocalPK(localPK) else {
                    throw ExportServiceError.selectorNotFound
                }
                resolved = try resolve(book)
            case let .pdfSourceID(rawValue):
                guard let source = try pdfSourceResolver.resolve(
                    sourceID: PDFSourceID.parse(rawValue), bookQueries: bookQueries
                ) else { throw ExportServiceError.selectorNotFound }
                let canonical: PDFSource
                if let localPK = source.bookSummary?.localPK,
                   let book = try bookQueries.getByLocalPK(localPK),
                   let current = try pdfSourceResolver.exportSource(book: book, bookQueries: bookQueries) {
                    canonical = current
                } else {
                    canonical = source
                }
                resolved = pdf(canonical)
            }
            if seen.insert(resolved.key).inserted { sources.append(resolved) }
        }
        return sources
    }

    private func resolve(_ book: Book) throws -> ResolvedExportSource {
        if book.contentType == 3 {
            guard let source = try pdfSourceResolver.exportSource(book: book, bookQueries: bookQueries) else {
                throw ExportServiceError.pdfSourceUnavailable
            }
            return pdf(source)
        }
        if let assetID = book.assetID {
            _ = try bookQueries.getUniqueByAssetID(assetID)
        }
        return ResolvedExportSource(
            key: .currentBook(book.localPK), epubAssetID: book.assetID,
            pdfSource: nil, requiresHistoricalEvidence: false
        )
    }

    private func pdf(_ source: PDFSource) -> ResolvedExportSource {
        ResolvedExportSource(
            key: .pdfSlot(source.fileURL.path), epubAssetID: nil,
            pdfSource: source, requiresHistoricalEvidence: false
        )
    }
}

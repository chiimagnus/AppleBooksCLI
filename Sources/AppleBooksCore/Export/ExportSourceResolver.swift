import CryptoKit
import Foundation

enum ResolvedExportSourceKey: Hashable, Sendable {
    case currentBook(Int64)
    case epubAsset(String)
    case epubUnknown
    case pdfBookAsset(String)
    case pdfSourceID(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.currentBook(left), .currentBook(right)): left == right
        case (.epubUnknown, .epubUnknown): true
        case let (.epubAsset(left), .epubAsset(right)),
             let (.pdfBookAsset(left), .pdfBookAsset(right)),
             let (.pdfSourceID(left), .pdfSourceID(right)):
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
            hashBytes(tag: 1, rawValue: rawValue, into: &hasher)
        case .epubUnknown:
            hasher.combine(2)
        case let .pdfBookAsset(rawValue):
            hashBytes(tag: 3, rawValue: rawValue, into: &hasher)
        case let .pdfSourceID(rawValue):
            hashBytes(tag: 4, rawValue: rawValue, into: &hasher)
        }
    }

    private func hashBytes(tag: UInt8, rawValue: String, into hasher: inout Hasher) {
        hasher.combine(tag)
        for byte in rawValue.utf8 { hasher.combine(byte) }
    }

    static func documentKey(for source: PDFSource) throws -> Self {
        if let sourceID = source.pdfSourceID {
            return .pdfSourceID(sourceID)
        }
        if let assetID = source.book?.assetID ?? source.bookSummary?.assetID {
            return .pdfBookAsset(assetID)
        }
        throw ExportServiceError.pdfSourceUnavailable
    }

    var documentSourceKind: ExportDocumentSourceKind? {
        switch self {
        case .currentBook:
            nil
        case .epubAsset, .epubUnknown:
            .epub
        case .pdfBookAsset, .pdfSourceID:
            .pdf
        }
    }

    func updateDocumentDigest(
        _ hasher: inout SHA256,
        observeBufferedBytes: ((Int) -> Void)? = nil
    ) throws {
        let domain: String
        let rawValue: String?
        switch self {
        case .currentBook:
            throw ExportDocumentIdentityError.invalidSourceKey
        case let .epubAsset(value):
            domain = "epub-asset"
            rawValue = value
        case .epubUnknown:
            domain = "epub-unmapped-unknown-source"
            rawValue = nil
        case let .pdfBookAsset(value):
            domain = "pdf-book-asset"
            rawValue = value
        case let .pdfSourceID(value):
            domain = "pdf-source-id"
            rawValue = value
        }
        hasher.update(data: Data("applebookscli.export.document.v1\0\(domain)\0".utf8))
        guard let rawValue else { return }

        var buffer: [UInt8] = []
        buffer.reserveCapacity(4_096)
        for byte in rawValue.utf8 {
            buffer.append(byte)
            observeBufferedBytes?(buffer.count)
            if buffer.count == 4_096 {
                hasher.update(data: Data(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            hasher.update(data: Data(buffer))
        }
    }
}

enum ExportDocumentSourceKind: UInt8, Comparable, Sendable {
    case epub = 0
    case pdf = 1

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ExportDocumentIdentityError: Error, Equatable, Sendable {
    case invalidSourceKey
    case invalidDigest
}

struct ExportDocumentIdentity: Equatable, Comparable, Sendable {
    static let prefix = "doc1_"
    static let digestByteCount = 32

    let sourceKind: ExportDocumentSourceKind
    let fullKey: String

    static func make(
        sourceKey: ResolvedExportSourceKey,
        digest: (ResolvedExportSourceKey) throws -> [UInt8] = { try defaultDigest(for: $0) }
    ) throws -> Self {
        guard let sourceKind = sourceKey.documentSourceKind else {
            throw ExportDocumentIdentityError.invalidSourceKey
        }
        let bytes = try digest(sourceKey)
        guard bytes.count == digestByteCount else {
            throw ExportDocumentIdentityError.invalidDigest
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return Self(sourceKind: sourceKind, fullKey: prefix + hex)
    }

    static func defaultDigest(
        for sourceKey: ResolvedExportSourceKey,
        observeBufferedBytes: ((Int) -> Void)? = nil
    ) throws -> [UInt8] {
        var hasher = SHA256()
        try sourceKey.updateDocumentDigest(&hasher, observeBufferedBytes: observeBufferedBytes)
        return Array(hasher.finalize())
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.sourceKind != rhs.sourceKind { return lhs.sourceKind < rhs.sourceKind }
        return lhs.fullKey.utf8.lexicographicallyPrecedes(rhs.fullKey.utf8)
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
                resolved = try pdf(canonical)
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
            return try pdf(source)
        }
        if let assetID = book.assetID {
            _ = try bookQueries.getUniqueByAssetID(assetID)
        }
        return ResolvedExportSource(
            key: .currentBook(book.localPK), epubAssetID: book.assetID,
            pdfSource: nil, requiresHistoricalEvidence: false
        )
    }

    private func pdf(_ source: PDFSource) throws -> ResolvedExportSource {
        ResolvedExportSource(
            key: try .documentKey(for: source), epubAssetID: nil,
            pdfSource: source, requiresHistoricalEvidence: false
        )
    }
}

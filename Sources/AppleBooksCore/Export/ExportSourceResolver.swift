import CryptoKit
import Foundation

enum ResolvedExportSourceKey: Hashable, Sendable {
    case currentBook(Int64)
    case epubAsset(String)
    case epubUnknown

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.currentBook(left), .currentBook(right)): left == right
        case (.epubUnknown, .epubUnknown): true
        case let (.epubAsset(left), .epubAsset(right)):
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
        case .epubUnknown:
            hasher.combine(2)
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

enum ExportDocumentIdentityError: Error, Equatable, Sendable {
    case invalidSourceKey
    case invalidDigest
}

struct ExportDocumentIdentity: Equatable, Comparable, Sendable {
    static let prefix = "doc1_"
    static let digestByteCount = 32

    let fullKey: String

    static func make(
        sourceKey: ResolvedExportSourceKey,
        digest: (ResolvedExportSourceKey) throws -> [UInt8] = { try defaultDigest(for: $0) }
    ) throws -> Self {
        guard case .currentBook = sourceKey else {
            let bytes = try digest(sourceKey)
            guard bytes.count == digestByteCount else {
                throw ExportDocumentIdentityError.invalidDigest
            }
            return Self(fullKey: prefix + bytes.map { String(format: "%02x", $0) }.joined())
        }
        throw ExportDocumentIdentityError.invalidSourceKey
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
        lhs.fullKey.utf8.lexicographicallyPrecedes(rhs.fullKey.utf8)
    }
}

struct ResolvedExportSource {
    let key: ResolvedExportSourceKey
    let epubAssetID: String?
    let requiresHistoricalEvidence: Bool
}

struct ExportSourceResolver {
    let bookQueries: BookQueries

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
                        key: .epubAsset(assetID),
                        epubAssetID: assetID,
                        requiresHistoricalEvidence: true
                    )
                }
            case let .localPK(localPK):
                guard let book = try bookQueries.getByLocalPK(localPK) else {
                    throw ExportServiceError.selectorNotFound
                }
                resolved = try resolve(book)
            }
            if seen.insert(resolved.key).inserted { sources.append(resolved) }
        }
        return sources
    }

    private func resolve(_ book: Book) throws -> ResolvedExportSource {
        guard book.contentType != 3 else {
            throw ExportServiceError.unsupportedBookFormat
        }
        if let assetID = book.assetID {
            _ = try bookQueries.getUniqueByAssetID(assetID)
        }
        return ResolvedExportSource(
            key: .currentBook(book.localPK),
            epubAssetID: book.assetID,
            requiresHistoricalEvidence: false
        )
    }
}

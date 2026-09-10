import CryptoKit
import Foundation

package enum PDFInventoryError: Error, Equatable, Sendable {
    case invalidSourceID
    case ambiguousSourceID
}

package struct PDFSourceID: Equatable, Hashable, Sendable {
    package static let prefix = "pdf1_"
    package static let digestByteCount = 32
    package static let encodedLength = 5 + digestByteCount * 2

    package let rawValue: String

    package static func parse(_ rawValue: String) throws -> Self {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == encodedLength,
              bytes.starts(with: prefix.utf8),
              bytes.dropFirst(prefix.utf8.count).allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
              }) else {
            throw PDFInventoryError.invalidSourceID
        }
        return Self(rawValue: rawValue)
    }

    static func make(payload: Data, digest: (Data) -> [UInt8]) throws -> Self {
        let bytes = digest(payload)
        guard bytes.count == digestByteCount else {
            throw CursorPaginationError.internalContractFailure
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return Self(rawValue: prefix + hex)
    }

    static func defaultDigest(_ payload: Data) -> [UInt8] {
        Array(SHA256.hash(data: payload))
    }

    var digestBytes: [UInt8] {
        let hex = rawValue.dropFirst(Self.prefix.count)
        var result: [UInt8] = []
        result.reserveCapacity(Self.digestByteCount)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
}

package struct PDFInventorySummary: Equatable, Sendable {
    package let bookAssetID: String?
    package let pdfSourceID: String?
    package let title: String?
    package let provenance: PDFSourceProvenance
    package let byteTruncatedFields: [String]
}

public enum PDFSourceProvenance: String, Equatable, Sendable {
    case library
    case fallback
}

public struct PDFSource: Equatable, Sendable {
    public let fileURL: URL
    public let book: Book?
    public let bookSummary: BookSummary?
    public let displayTitle: String
    public let provenance: PDFSourceProvenance
    package let pdfSourceID: String?

    init(fileURL: URL, book: Book?, provenance: PDFSourceProvenance? = nil, pdfSourceID: String? = nil) {
        self.fileURL = fileURL
        self.book = book
        bookSummary = nil
        self.provenance = provenance ?? (book == nil ? .fallback : .library)
        self.pdfSourceID = pdfSourceID
        if let title = book?.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            displayTitle = title
        } else {
            displayTitle = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    package init(
        fileURL: URL,
        bookSummary: BookSummary?,
        provenance: PDFSourceProvenance,
        pdfSourceID: String? = nil
    ) {
        self.fileURL = fileURL
        book = nil
        self.bookSummary = bookSummary
        self.provenance = provenance
        self.pdfSourceID = pdfSourceID
        if let title = bookSummary?.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            displayTitle = title
        } else {
            displayTitle = fileURL.deletingPathExtension().lastPathComponent
        }
    }
}

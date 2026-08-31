import Foundation

public struct Book: Equatable, Sendable {
    public let localPK: Int64
    public let assetID: String?
    public let title: String?
    public let author: String?
    public let description: String?
    public let epubID: String?
    public let genre: String?
    public let genresRaw: Data?
    public let comments: String?
    public let language: String?
    public let year: Int64?
    public let contentType: Int64?
    public let pageCount: Int64?
    public let path: String?
    public let fileSize: Int64?
    public let coverURL: String?
    public let isFinished: Bool?
    public let readingProgressRaw: Double?
    public let durationRawMilliseconds: Double?
    public let creationDate: Date?
    public let modificationDate: Date?
    public let finishedDate: Date?
    public let lastOpenDate: Date?
    public let purchaseDate: Date?
    public let releaseDate: Date?
    public let isExplicit: Bool?
    public let isLocked: Bool?
    public let isEphemeral: Bool?
    public let isHidden: Bool?
    public let isSample: Bool?
    public let isStoreAudiobook: Bool?
    public let rating: Double?

    public var normalizedAuthor: String? {
        guard let author else { return nil }
        let scalars = author.unicodeScalars.filter { scalar in
            scalar.value < 0xE000 || scalar.value > 0xF8FF
        }
        let normalized = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { return nil }
        switch normalized.lowercased() {
        case "unknown", "unknownauthor", "unknown author":
            return nil
        default:
            return normalized
        }
    }

    public var readingProgressPercent: Double? {
        readingProgressRaw.map { $0 * 100 }
    }

    public var durationSeconds: Double? {
        durationRawMilliseconds.map { $0 / 1_000 }
    }
}

import Foundation

public struct Book: Equatable, Sendable {
    public let localPK: Int64
    public let assetID: String?
    public let title: String?
    public let author: String?
    public let description: String?
    public let genre: String?
    public let contentType: Int64?
    public let pageCount: Int64?
    public let path: String?
    public let fileSize: Int64?
    public let isFinished: Bool?
    public let readingProgressRaw: Double?
    public let durationRawMilliseconds: Double?
    public let creationDate: Date?
    public let finishedDate: Date?
    public let lastOpenDate: Date?
    public let purchaseDate: Date?
    public let isExplicit: Bool?
    public let isLocked: Bool?
    public let isEphemeral: Bool?
    public let isHidden: Bool?
    public let isSample: Bool?
    public let isStoreAudiobook: Bool?
    public let rating: Double?

    public var readingProgressPercent: Double? {
        readingProgressRaw.map { $0 * 100 }
    }

    public var durationSeconds: Double? {
        durationRawMilliseconds.map { $0 / 1_000 }
    }
}

import Foundation

public struct SemanticBookDetail: Equatable, Sendable {
    public let localPK: Int64
    public let assetID: String?
    public let title: String?
    public let author: String?
    public let description: String?
    public let genre: String?
    public let language: String?
    public let year: Int64?
    public let pageCount: Int64?
    public let contentType: Int64?
    public let readingProgressRaw: Double?
    public let isFinished: Bool?
    public let finishedDate: Date?
    public let lastOpenDate: Date?
    public let releaseDate: Date?
    public let byteTruncatedFields: [String]

    public var isPDF: Bool? { contentType.map { $0 == 3 } }
}

struct BookResourceTarget: Equatable, Sendable {
    let localPK: Int64
    let assetID: String?
    let contentType: Int64?
    let path: String?
}

package struct BookContentMetadataFallback: Equatable, Sendable {
    package let title: String?
    package let author: String?
    package let language: String?
    package let releaseDate: Date?
    package let byteTruncatedFields: [String]
}

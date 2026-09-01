import Foundation

public struct Collection: Equatable, Sendable {
    public let localPK: Int64
    public let collectionID: String?
    public let title: String?
    public let details: String?
    public let isDeleted: Bool?
    public let isHidden: Bool?
    public let isPlaceholder: Bool?
    public let sortKey: Int64?
    public let sortMode: Int64?
    public let viewMode: Int64?
    public let lastModificationDate: Date?
    public let localModificationDate: Date?
}

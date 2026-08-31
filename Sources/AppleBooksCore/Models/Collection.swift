public struct Collection: Equatable, Sendable {
    public let localPK: Int64
    public let collectionID: String?
    public let title: String?
    public let details: String?
    public let isDeleted: Bool?
    public let isHidden: Bool?
}

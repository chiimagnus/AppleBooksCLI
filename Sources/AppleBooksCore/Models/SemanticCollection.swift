package struct SemanticCollectionSummary: Equatable, Sendable {
    package let localPK: Int64
    package let collectionID: String?
    package let title: String?
    package let canEditCollection: Bool
    package let canEditMembership: Bool
    package let byteTruncatedFields: [String]
}

package struct SemanticCollection: Equatable, Sendable {
    package let localPK: Int64
    package let collectionID: String?
    package let title: String?
    package let details: String?
    package let isHidden: Bool?
    package let canEditCollection: Bool
    package let canEditMembership: Bool
    package let byteTruncatedFields: [String]
}

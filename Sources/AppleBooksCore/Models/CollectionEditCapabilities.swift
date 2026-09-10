import Foundation

struct CollectionEditCapabilities: Equatable, Sendable {
    let canEditCollection: Bool
    let canEditMembership: Bool
}

enum CollectionIdentityEditPolicy {
    static let membershipEditableSystemID = "Want_To_Read_Collection_ID"

    static func capabilities(for rawCollectionID: String?) -> CollectionEditCapabilities {
        guard let rawCollectionID else {
            return CollectionEditCapabilities(canEditCollection: false, canEditMembership: false)
        }
        if rawCollectionID == membershipEditableSystemID {
            return CollectionEditCapabilities(canEditCollection: false, canEditMembership: true)
        }
        if UUID(uuidString: rawCollectionID) != nil {
            return CollectionEditCapabilities(canEditCollection: true, canEditMembership: true)
        }
        return CollectionEditCapabilities(canEditCollection: false, canEditMembership: false)
    }
}

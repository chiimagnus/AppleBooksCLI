import AppleBooksCore

struct AnnotationMutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let annotationUUID: String?
    let annotationLocalPK: Int64?
    let acknowledgementRequested: Bool
    @ExplicitNullBool var acknowledged: Bool?
    let warningCodes: [String]

    init(_ result: MutationResult, selector: AnnotationSelector) {
        committed = result.committed
        changed = result.changed
        switch selector {
        case let .uuid(uuid):
            annotationUUID = result.stableID ?? uuid
            annotationLocalPK = nil
        case .localPK:
            annotationUUID = result.stableID
            annotationLocalPK = result.stableID == nil ? result.localPK : nil
        }
        acknowledgementRequested = result.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: result.acknowledged)
        warningCodes = result.warnings.map(\.rawValue)
    }
}

struct CollectionMutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let backupID: String?
    let collectionID: String?
    let collectionLocalPK: Int64?
    let acknowledgementRequested: Bool
    @ExplicitNullBool var acknowledged: Bool?
    let warningCodes: [String]

    init(_ result: MutationResult, selector: CollectionSelector? = nil) {
        committed = result.committed
        changed = result.changed
        backupID = result.backupID
        let selectedStableID: String? = switch selector {
        case let .collectionID(collectionID): collectionID
        case .localPK, .none: nil
        }
        collectionID = result.stableID ?? selectedStableID
        collectionLocalPK = collectionID == nil ? result.localPK : nil
        acknowledgementRequested = result.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: result.acknowledged)
        warningCodes = result.warnings.map(\.rawValue)
    }
}

struct MembershipMutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let backupID: String?
    let collectionID: String?
    let collectionLocalPK: Int64?
    let bookAssetID: String?
    let bookLocalPK: Int64?
    let acknowledgementRequested: Bool
    @ExplicitNullBool var acknowledged: Bool?
    let warningCodes: [String]

    init(_ result: MutationResult, collection: CollectionSelector, book: BookSelector) {
        committed = result.committed
        changed = result.changed
        backupID = result.backupID
        switch collection {
        case let .collectionID(collectionID):
            self.collectionID = result.stableID ?? collectionID
            collectionLocalPK = nil
        case .localPK:
            collectionID = result.stableID
            collectionLocalPK = result.stableID == nil ? result.localPK : nil
        }
        let selectedBookAssetID: String? = switch book {
        case let .assetID(assetID): assetID
        case .localPK: nil
        }
        let selectedBookLocalPK: Int64? = switch book {
        case .assetID: nil
        case let .localPK(localPK): localPK
        }
        bookAssetID = result.relatedStableID ?? selectedBookAssetID
        bookLocalPK = bookAssetID == nil ? (result.relatedLocalPK ?? selectedBookLocalPK) : nil
        acknowledgementRequested = result.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: result.acknowledged)
        warningCodes = result.warnings.map(\.rawValue)
    }
}

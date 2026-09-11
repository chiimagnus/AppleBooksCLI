import AppleBooksCore

private struct MutationOutcome {
    let committed: Bool
    let changed: Bool
    let acknowledgementRequested: Bool
    let acknowledged: Bool?
    let warningCodes: [String]

    init(_ result: MutationResult) {
        committed = result.committed
        changed = result.changed
        acknowledgementRequested = result.acknowledgementRequested
        acknowledged = result.acknowledged
        warningCodes = result.warnings.map(\.rawValue)
    }
}

struct AnnotationMutationCommandResult: Codable, Equatable, Sendable {
    let committed: Bool
    let changed: Bool
    let annotationUUID: String?
    let annotationLocalPK: Int64?
    let acknowledgementRequested: Bool
    @ExplicitNullBool var acknowledged: Bool?
    let warningCodes: [String]

    init(_ result: MutationResult, selector: AnnotationSelector) {
        let outcome = MutationOutcome(result)
        committed = outcome.committed
        changed = outcome.changed
        switch selector {
        case let .uuid(uuid):
            annotationUUID = result.stableID ?? uuid
            annotationLocalPK = nil
        case .localPK:
            annotationUUID = result.stableID
            annotationLocalPK = result.stableID == nil ? result.localPK : nil
        }
        acknowledgementRequested = outcome.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: outcome.acknowledged)
        warningCodes = outcome.warningCodes
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
        let outcome = MutationOutcome(result)
        committed = outcome.committed
        changed = outcome.changed
        backupID = result.backupID
        let selectedStableID: String? = switch selector {
        case let .collectionID(collectionID): collectionID
        case .localPK, .none: nil
        }
        collectionID = result.stableID ?? selectedStableID
        collectionLocalPK = collectionID == nil ? result.localPK : nil
        acknowledgementRequested = outcome.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: outcome.acknowledged)
        warningCodes = outcome.warningCodes
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
        let outcome = MutationOutcome(result)
        committed = outcome.committed
        changed = outcome.changed
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
        acknowledgementRequested = outcome.acknowledgementRequested
        _acknowledged = ExplicitNullBool(wrappedValue: outcome.acknowledged)
        warningCodes = outcome.warningCodes
    }
}

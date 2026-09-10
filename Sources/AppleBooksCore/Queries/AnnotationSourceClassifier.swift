package enum AnnotationSourceClassificationError: Error, Equatable, Sendable {
    case schemaUnavailable
}

enum AnnotationAssetSourceState: Equatable, Sendable {
    case current(localPK: Int64)
    case historical
    case unmapped
    case ambiguousCurrent
    case identityUnavailable
    case schemaUnavailable
}

struct AnnotationSourceClassifier {
    static let maximumBatch = 100

    let bookQueries: BookQueries
    let historicalAssets: HistoricalAssets

    func classify(_ assetIDs: [String]) throws -> [String: AnnotationAssetSourceState] {
        guard assetIDs.count <= Self.maximumBatch else {
            throw AnnotationAggregateQueryError.batchTooLarge
        }
        let unique = Array(Set(assetIDs))
        guard unique.isEmpty == false else { return [:] }

        let matches: [String: BookIdentityMultiplicity]
        do {
            matches = try bookQueries.identityMultiplicity(assetIDs: unique)
        } catch is SchemaCompatibilityError {
            return Dictionary(uniqueKeysWithValues: unique.map { assetID in
                if historicalAssets.metadata(for: assetID) != nil {
                    return (assetID, .historical)
                }
                return (assetID, .schemaUnavailable)
            })
        }

        return Dictionary(uniqueKeysWithValues: unique.map { assetID in
            if let match = matches[assetID] {
                if match.count == 1, let localPK = match.uniqueLocalPK {
                    return (assetID, .current(localPK: localPK))
                }
                if match.count > 1 {
                    return (assetID, .ambiguousCurrent)
                }
            }
            if historicalAssets.metadata(for: assetID) != nil {
                return (assetID, .historical)
            }
            return (assetID, .unmapped)
        })
    }

    func classifyRawIdentity(_ assetID: String?) -> AnnotationAssetSourceState? {
        guard let assetID else { return .unmapped }
        guard PublicStableIdentityPolicy.isEligible(assetID) else { return .identityUnavailable }
        return nil
    }
}

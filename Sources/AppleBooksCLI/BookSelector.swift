import ArgumentParser

enum BookSelector: Equatable, Sendable {
    case assetID(String)
    case localPK(Int64)
}

func parseBookSelector(assetID: String?, localPK: Int64?) throws -> BookSelector {
    switch (assetID, localPK) {
    case let (.some(assetID), nil):
        guard assetID.isEmpty == false else {
            throw ValidationError("Asset ID must not be empty.")
        }
        return .assetID(assetID)
    case let (nil, .some(localPK)):
        return .localPK(localPK)
    case (nil, nil):
        throw ValidationError("Provide an asset ID or --pk.")
    case (.some, .some):
        throw ValidationError("Asset ID and --pk are mutually exclusive.")
    }
}

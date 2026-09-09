import AppleBooksCore
import ArgumentParser

enum BookSelector: Equatable, Sendable {
    case assetID(String)
    case localPK(Int64)

    func resolveSemanticDetail(in books: AppleBooks) throws -> SemanticBookDetail? {
        switch self {
        case let .assetID(assetID):
            try books.semanticBookDetail(assetID: assetID)
        case let .localPK(localPK):
            try books.semanticBookDetail(localPK: localPK)
        }
    }

}

func parseBookSelector(assetID: String?, localPK: Int64?) throws -> BookSelector {
    guard let selector = try parseOptionalBookSelector(assetID: assetID, localPK: localPK) else {
        throw ValidationError("Provide an asset ID or --pk.")
    }
    return selector
}

func parseOptionalBookSelector(
    assetID: String?,
    localPK: Int64?,
    localPKOptionName: String = "--pk"
) throws -> BookSelector? {
    switch (assetID, localPK) {
    case let (.some(assetID), nil):
        try PublicStableTokenPolicy.validateInput(assetID)
        return .assetID(assetID)
    case let (nil, .some(localPK)):
        try LocalPKPolicy.validateInput(localPK, optionName: localPKOptionName)
        return .localPK(localPK)
    case (nil, nil):
        return nil
    case (.some, .some):
        throw ValidationError("Asset ID and \(localPKOptionName) are mutually exclusive.")
    }
}

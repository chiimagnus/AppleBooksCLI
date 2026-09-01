import AppleBooksCore
import ArgumentParser

enum BookSelector: Equatable, Sendable {
    case assetID(String)
    case localPK(Int64)

    func resolve(in books: AppleBooks) throws -> Book? {
        switch self {
        case let .assetID(assetID):
            try books.book(assetID: assetID)
        case let .localPK(localPK):
            try books.book(localPK: localPK)
        }
    }

    func resolveOverview(in books: AppleBooks) throws -> BookOverview? {
        switch self {
        case let .assetID(assetID):
            try books.bookOverview(assetID: assetID)
        case let .localPK(localPK):
            try books.bookOverview(localPK: localPK)
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
        guard assetID.isEmpty == false else {
            throw ValidationError("Asset ID must not be empty.")
        }
        return .assetID(assetID)
    case let (nil, .some(localPK)):
        return .localPK(localPK)
    case (nil, nil):
        return nil
    case (.some, .some):
        throw ValidationError("Asset ID and \(localPKOptionName) are mutually exclusive.")
    }
}

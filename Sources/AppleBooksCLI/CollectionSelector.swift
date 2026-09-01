import AppleBooksCore
import ArgumentParser

enum CollectionSelector: Equatable, Sendable {
    case collectionID(String)
    case localPK(Int64)

    func resolve(in books: AppleBooks) throws -> Collection? {
        switch self {
        case let .collectionID(collectionID):
            try books.collection(collectionID: collectionID)
        case let .localPK(localPK):
            try books.collection(localPK: localPK)
        }
    }

    func resolveBooks(in books: AppleBooks) throws -> [Book]? {
        switch self {
        case let .collectionID(collectionID):
            try books.books(inCollectionID: collectionID)
        case let .localPK(localPK):
            try books.books(inCollectionLocalPK: localPK)
        }
    }
}

func parseCollectionSelector(collectionID: String?, localPK: Int64?) throws -> CollectionSelector {
    switch (collectionID, localPK) {
    case let (.some(collectionID), nil):
        guard collectionID.isEmpty == false else {
            throw ValidationError("Collection ID must not be empty.")
        }
        return .collectionID(collectionID)
    case let (nil, .some(localPK)):
        return .localPK(localPK)
    case (nil, nil):
        throw ValidationError("Provide a collection ID or --pk.")
    case (.some, .some):
        throw ValidationError("Collection ID and --pk are mutually exclusive.")
    }
}

import AppleBooksCore
import ArgumentParser

enum CollectionSelector: Equatable, Sendable {
    case collectionID(String)
    case localPK(Int64)

    func resolveSemantic(in books: AppleBooks) throws -> SemanticCollection? {
        switch self {
        case let .collectionID(collectionID):
            try books.semanticCollection(collectionID: collectionID)
        case let .localPK(localPK):
            try books.semanticCollection(localPK: localPK)
        }
    }

    func resolveBookSummaryPage(
        in books: AppleBooks,
        limit: Int?,
        cursor: String?
    ) throws -> CursorPage<BookSummary>? {
        switch self {
        case let .collectionID(collectionID):
            try books.semanticBookSummaryPage(inCollectionID: collectionID, limit: limit, cursor: cursor)
        case let .localPK(localPK):
            try books.semanticBookSummaryPage(inCollectionLocalPK: localPK, limit: limit, cursor: cursor)
        }
    }

    func rename(to title: String, in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch self {
        case let .collectionID(collectionID):
            try books.renameCollection(collectionID: collectionID, newTitle: title, syncCloud: syncCloud)
        case let .localPK(localPK):
            try books.renameCollection(localPK: localPK, newTitle: title, syncCloud: syncCloud)
        }
    }

    func delete(in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch self {
        case let .collectionID(collectionID):
            try books.deleteCollection(collectionID: collectionID, syncCloud: syncCloud)
        case let .localPK(localPK):
            try books.deleteCollection(localPK: localPK, syncCloud: syncCloud)
        }
    }

    func add(_ book: BookSelector, in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch (self, book) {
        case let (.collectionID(collectionID), .assetID(assetID)):
            try books.addBook(assetID: assetID, toCollectionID: collectionID, syncCloud: syncCloud)
        case let (.collectionID(collectionID), .localPK(bookLocalPK)):
            try books.addBook(bookLocalPK: bookLocalPK, toCollectionID: collectionID, syncCloud: syncCloud)
        case let (.localPK(collectionLocalPK), .assetID(assetID)):
            try books.addBook(assetID: assetID, toCollectionLocalPK: collectionLocalPK, syncCloud: syncCloud)
        case let (.localPK(collectionLocalPK), .localPK(bookLocalPK)):
            try books.addBook(bookLocalPK: bookLocalPK, toCollectionLocalPK: collectionLocalPK, syncCloud: syncCloud)
        }
    }

    func remove(_ book: BookSelector, in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch (self, book) {
        case let (.collectionID(collectionID), .assetID(assetID)):
            try books.removeBook(assetID: assetID, fromCollectionID: collectionID, syncCloud: syncCloud)
        case let (.collectionID(collectionID), .localPK(bookLocalPK)):
            try books.removeBook(bookLocalPK: bookLocalPK, fromCollectionID: collectionID, syncCloud: syncCloud)
        case let (.localPK(collectionLocalPK), .assetID(assetID)):
            try books.removeBook(assetID: assetID, fromCollectionLocalPK: collectionLocalPK, syncCloud: syncCloud)
        case let (.localPK(collectionLocalPK), .localPK(bookLocalPK)):
            try books.removeBook(bookLocalPK: bookLocalPK, fromCollectionLocalPK: collectionLocalPK, syncCloud: syncCloud)
        }
    }
}

func parseCollectionSelector(
    collectionID: String?,
    localPK: Int64?,
    localPKOptionName: String = "--pk"
) throws -> CollectionSelector {
    switch (collectionID, localPK) {
    case let (.some(collectionID), nil):
        guard PublicStableTokenPolicy.isEligible(collectionID) else {
            throw ValidationError("Collection ID is invalid or too long.")
        }
        return .collectionID(collectionID)
    case let (nil, .some(localPK)):
        try LocalPKPolicy.validateInput(localPK, optionName: localPKOptionName)
        return .localPK(localPK)
    case (nil, nil):
        throw ValidationError("Provide a collection ID or --pk.")
    case (.some, .some):
        throw ValidationError("Collection ID and \(localPKOptionName) are mutually exclusive.")
    }
}

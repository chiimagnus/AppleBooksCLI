import AppleBooksCore
import ArgumentParser

enum AnnotationSelector: Equatable, Sendable {
    case uuid(String)
    case localPK(Int64)

    func resolveSemantic(in books: AppleBooks, scope: AnnotationScope = .user) throws -> SemanticAnnotation? {
        switch self {
        case let .uuid(uuid):
            try books.semanticAnnotation(uuid: uuid, scope: scope)
        case let .localPK(localPK):
            try books.semanticAnnotation(localPK: localPK, scope: scope)
        }
    }

    func updateNote(_ note: String, in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch self {
        case let .uuid(uuid):
            try books.updateAnnotationNote(uuid: uuid, note: note, syncCloud: syncCloud)
        case let .localPK(localPK):
            try books.updateAnnotationNote(localPK: localPK, note: note, syncCloud: syncCloud)
        }
    }

    func delete(in books: AppleBooks, syncCloud: Bool = false) throws -> MutationResult {
        switch self {
        case let .uuid(uuid):
            try books.deleteAnnotation(uuid: uuid, syncCloud: syncCloud)
        case let .localPK(localPK):
            try books.deleteAnnotation(localPK: localPK, syncCloud: syncCloud)
        }
    }
}

func parseAnnotationSelector(uuid: String?, localPK: Int64?) throws -> AnnotationSelector {
    switch (uuid, localPK) {
    case let (.some(uuid), nil):
        try PublicStableTokenPolicy.validateInput(uuid)
        return .uuid(uuid)
    case let (nil, .some(localPK)):
        try LocalPKPolicy.validateInput(localPK)
        return .localPK(localPK)
    case (nil, nil):
        throw ValidationError("Provide an annotation UUID or --pk.")
    case (.some, .some):
        throw ValidationError("Annotation UUID and --pk are mutually exclusive.")
    }
}

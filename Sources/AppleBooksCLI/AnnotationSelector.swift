import AppleBooksCore
import ArgumentParser

enum AnnotationSelector: Equatable, Sendable {
    case uuid(String)
    case localPK(Int64)

    func resolve(in books: AppleBooks, scope: AnnotationScope = .user) throws -> EnrichedAnnotation? {
        switch self {
        case let .uuid(uuid):
            try books.annotation(uuid: uuid, scope: scope)
        case let .localPK(localPK):
            try books.annotation(localPK: localPK, scope: scope)
        }
    }
}

func parseAnnotationSelector(uuid: String?, localPK: Int64?) throws -> AnnotationSelector {
    switch (uuid, localPK) {
    case let (.some(uuid), nil):
        guard uuid.isEmpty == false else {
            throw ValidationError("Annotation UUID must not be empty.")
        }
        return .uuid(uuid)
    case let (nil, .some(localPK)):
        return .localPK(localPK)
    case (nil, nil):
        throw ValidationError("Provide an annotation UUID or --pk.")
    case (.some, .some):
        throw ValidationError("Annotation UUID and --pk are mutually exclusive.")
    }
}

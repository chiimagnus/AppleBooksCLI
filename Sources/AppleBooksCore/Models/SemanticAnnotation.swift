import Foundation

public struct AnnotationProjectionRepairResult: Codable, Equatable, Sendable {
    public let annotationUUID: String
    public let verified: Bool
    public let warningCodes: [String]
}

public struct AnnotationCreationRequest: Sendable {
    public let text: String
    public let chapterOrder: Int?
    public let prefix: String?
    public let suffix: String?
    public let occurrence: Int?
    public let note: String?
    public let color: AnnotationColor
    public let underline: Bool

    public init(
        text: String, chapterOrder: Int? = nil,
        prefix: String? = nil, suffix: String? = nil,
        occurrence: Int? = nil, note: String? = nil,
        color: AnnotationColor = .yellow, underline: Bool = false
    ) {
        self.text = text
        self.chapterOrder = chapterOrder
        self.prefix = prefix
        self.suffix = suffix
        self.occurrence = occurrence
        self.note = note
        self.color = color
        self.underline = underline
    }
}

public struct AnnotationCreationPreview: Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready
        case alreadyExists = "already_exists"
    }
    public let status: Status
    public let existingUUID: String?
    public let chapterOrder: Int
}

public enum SemanticAnnotationSourceKind: String, Equatable, Sendable {
    case currentLibrary
    case historicalInferred
    case unmapped
    case ambiguousCurrent
    case identityUnavailable
    case schemaUnavailable
}

public struct SemanticAnnotationSource: Equatable, Sendable {
    public let kind: SemanticAnnotationSourceKind
    public let bookLocalPK: Int64?
    public let bookAssetID: String?
    public let title: String?
    public let author: String?
    public let byteTruncatedFields: [String]

    public init(
        kind: SemanticAnnotationSourceKind,
        bookLocalPK: Int64? = nil,
        bookAssetID: String? = nil,
        title: String? = nil,
        author: String? = nil,
        byteTruncatedFields: [String] = []
    ) {
        self.kind = kind
        self.bookLocalPK = bookLocalPK
        self.bookAssetID = bookAssetID
        self.title = title
        self.author = author
        self.byteTruncatedFields = byteTruncatedFields
    }
}

public struct SemanticAnnotation: Equatable, Sendable {
    public let localPK: Int64
    public let uuid: String?
    public let rawAssetID: String?
    public let isDeleted: Bool?
    public let isUnderline: Bool?
    public let style: Int64?
    public let type: Int64?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let representativeText: String?
    public let selectedText: String?
    public let note: String?
    public let hasHighlight: Bool
    public let hasNote: Bool
    public let rawCFI: String?
    public let chapterHint: String?
    public let physicalLocation: Int64?
    public let rangeStart: Int64?
    public let rangeEnd: Int64?
    public let source: SemanticAnnotationSource
    public let byteTruncatedFields: [String]

    public var appleBooksURL: String? {
        Annotation.appleBooksURL(rawAssetID: rawAssetID, rawCFI: rawCFI)
    }

    public var chapterID: String? {
        rawCFI.map(Location.init(rawCFI:))?.chapterID
    }
}

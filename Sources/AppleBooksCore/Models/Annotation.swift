import Foundation

public enum AnnotationScope: Equatable, Sendable {
    case user
    case activeRaw
}

public struct Annotation: Equatable, Sendable {
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
    public let location: Location?
    public let chapterHint: String?
    public let physicalLocation: Int64?
    public let rangeStart: Int64?
    public let rangeEnd: Int64?

    public var appleBooksURL: String? {
        guard let assetID = rawAssetID?.trimmingCharacters(in: .whitespacesAndNewlines),
              assetID.isEmpty == false else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "ibooks"
        components.host = "assetid"
        components.path = "/\(assetID)"
        if let cfi = location?.rawCFI.trimmingCharacters(in: .whitespacesAndNewlines), cfi.isEmpty == false {
            components.fragment = cfi
        }
        return components.url?.absoluteString
    }
}

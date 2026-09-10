import Foundation

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
        Self.appleBooksURL(rawAssetID: rawAssetID, rawCFI: location?.rawCFI)
    }

    package static func bookAppleBooksURL(assetID: String) -> String? {
        guard PublicStableIdentityPolicy.isEligible(assetID) else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let segment = assetID.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }

        var components = URLComponents()
        components.scheme = "ibooks"
        components.host = "assetid"
        components.percentEncodedPath = "/\(segment)"
        guard let url = components.url,
              let roundTrip = URLComponents(url: url, resolvingAgainstBaseURL: false),
              roundTrip.fragment == nil,
              roundTrip.query == nil,
              roundTrip.percentEncodedPath.first == "/",
              roundTrip.percentEncodedPath.dropFirst().contains("/") == false,
              String(roundTrip.percentEncodedPath.dropFirst()).removingPercentEncoding == assetID else {
            return nil
        }
        return url.absoluteString
    }

    static func appleBooksURL(rawAssetID: String?, rawCFI: String?) -> String? {
        guard let assetID = rawAssetID?.trimmingCharacters(in: .whitespacesAndNewlines),
              assetID.isEmpty == false else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "ibooks"
        components.host = "assetid"
        components.path = "/\(assetID)"
        if let rawCFI,
           CFIResourcePolicy.allowsStructuralParsing(rawCFI) {
            let cfi = rawCFI.trimmingCharacters(in: .whitespacesAndNewlines)
            if cfi.isEmpty == false {
                components.fragment = cfi
            }
        }
        return components.url?.absoluteString
    }
}

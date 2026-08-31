import Foundation

public enum EPUBPathError: Error, Equatable, Sendable {
    case invalidReference
    case rootEscape
}

struct EPUBPath: Equatable, Sendable {
    let relativePath: String
    let fragment: String?

    var directory: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    static func resolve(
        reference: String,
        relativeTo baseDirectory: String = ""
    ) throws -> EPUBPath {
        guard reference.isEmpty == false, reference.contains("\0") == false else {
            throw EPUBPathError.invalidReference
        }

        let rawParts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(rawParts[0])
        let rawFragment = rawParts.count == 2 ? String(rawParts[1]) : nil
        guard rawPath.isEmpty == false,
              rawPath.contains("?") == false,
              isExternalReference(rawPath) == false,
              let decodedPath = rawPath.removingPercentEncoding,
              decodedPath.contains("\0") == false,
              decodedPath.isEmpty == false,
              isExternalReference(decodedPath) == false else {
            throw EPUBPathError.invalidReference
        }

        let decodedFragment: String?
        if let rawFragment {
            guard let value = rawFragment.removingPercentEncoding, value.contains("\0") == false else {
                throw EPUBPathError.invalidReference
            }
            decodedFragment = value
        } else {
            decodedFragment = nil
        }

        var components = try normalizedBaseComponents(baseDirectory)
        for component in decodedPath.split(separator: "/", omittingEmptySubsequences: false) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard components.isEmpty == false else {
                    throw EPUBPathError.rootEscape
                }
                components.removeLast()
            default:
                components.append(String(component))
            }
        }
        guard components.isEmpty == false else {
            throw EPUBPathError.invalidReference
        }

        return EPUBPath(
            relativePath: components.joined(separator: "/"),
            fragment: decodedFragment
        )
    }

    private static func normalizedBaseComponents(_ baseDirectory: String) throws -> [String] {
        guard baseDirectory.hasPrefix("/") == false,
              baseDirectory.contains("\0") == false else {
            throw EPUBPathError.invalidReference
        }
        var result: [String] = []
        for component in baseDirectory.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                guard result.isEmpty == false else { throw EPUBPathError.rootEscape }
                result.removeLast()
            default:
                result.append(String(component))
            }
        }
        return result
    }

    private static func isExternalReference(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("//") {
            return true
        }
        let firstComponent = value.prefix { $0 != "/" }
        guard let colon = firstComponent.firstIndex(of: ":") else { return false }
        let scheme = firstComponent[..<colon]
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first) else {
            return false
        }
        let allowedPunctuation = CharacterSet(charactersIn: "+-.")
        return scheme.unicodeScalars.dropFirst().allSatisfy {
            CharacterSet.alphanumerics.contains($0) || allowedPunctuation.contains($0)
        }
    }

}

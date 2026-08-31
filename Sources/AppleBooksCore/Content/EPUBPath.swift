import Darwin
import Foundation

public enum EPUBPathError: Error, Equatable, Sendable {
    case invalidReference
    case rootEscape
    case missingRoot
    case symlink
    case unsupportedNode
}

struct EPUBPath: Equatable, Sendable {
    let relativePath: String
    let fragment: String?
    let url: URL

    var directory: String {
        guard let slash = relativePath.lastIndex(of: "/") else { return "" }
        return String(relativePath[..<slash])
    }

    static func resolve(
        root: URL,
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

        let relativePath = components.joined(separator: "/")
        let canonicalRoot = root.standardizedFileURL
        try validateRootAndComponents(root: canonicalRoot, components: components)
        return EPUBPath(
            relativePath: relativePath,
            fragment: decodedFragment,
            url: components.reduce(canonicalRoot) { $0.appendingPathComponent($1, isDirectory: false) }
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

    private static func validateRootAndComponents(root: URL, components: [String]) throws {
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw EPUBPathError.missingRoot }
            throw EPUBPathError.unsupportedNode
        }
        guard rootStat.st_mode & S_IFMT != S_IFLNK else { throw EPUBPathError.symlink }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else { throw EPUBPathError.unsupportedNode }

        var current = root
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component, isDirectory: false)
            var value = stat()
            guard lstat(current.path, &value) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { return }
                throw EPUBPathError.unsupportedNode
            }
            let type = value.st_mode & S_IFMT
            guard type != S_IFLNK else { throw EPUBPathError.symlink }
            if index < components.count - 1, type != S_IFDIR {
                throw EPUBPathError.unsupportedNode
            }
        }
    }
}

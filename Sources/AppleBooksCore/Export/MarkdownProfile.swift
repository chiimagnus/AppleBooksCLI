import Foundation

public enum MarkdownProfileSyntax: Equatable, Sendable {
    case plain
    case obsidian
}

public struct ObsidianMarkdownOptions: Equatable, Sendable {
    public var extendedFrontmatter: Bool
    public var bodyMetadata: Bool
    public var includeTags: Bool
    public var customTags: [String]
    public var chapterHeadings: Bool
    public var annotationDates: Bool
    public var annotationStyle: Bool
    public var readingProgress: Bool
    public var citation: Bool
    public var authorLinks: Bool
    public var authorPages: Bool
    public var groupConsecutiveNullLocationFragments: Bool

    public init(
        extendedFrontmatter: Bool = false,
        bodyMetadata: Bool = false,
        includeTags: Bool = false,
        customTags: [String] = [],
        chapterHeadings: Bool = false,
        annotationDates: Bool = false,
        annotationStyle: Bool = false,
        readingProgress: Bool = false,
        citation: Bool = false,
        authorLinks: Bool = false,
        authorPages: Bool = false,
        groupConsecutiveNullLocationFragments: Bool = false
    ) {
        self.extendedFrontmatter = extendedFrontmatter
        self.bodyMetadata = bodyMetadata
        self.includeTags = includeTags
        self.customTags = customTags
        self.chapterHeadings = chapterHeadings
        self.annotationDates = annotationDates
        self.annotationStyle = annotationStyle
        self.readingProgress = readingProgress
        self.citation = citation
        self.authorLinks = authorLinks
        self.authorPages = authorPages
        self.groupConsecutiveNullLocationFragments = groupConsecutiveNullLocationFragments
    }
}

public struct MarkdownProfile: Equatable, Sendable {
    public let syntax: MarkdownProfileSyntax
    public let options: ObsidianMarkdownOptions

    public init(syntax: MarkdownProfileSyntax, options: ObsidianMarkdownOptions = .init()) {
        self.syntax = syntax
        self.options = options
    }

    public static let plain = MarkdownProfile(syntax: .plain)
    public static let obsidian = MarkdownProfile(syntax: .obsidian)
}

enum MarkdownYAML {
    static func quotedScalar(_ value: String) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return encoded
    }

    static func frontmatter(fields: [(String, String?)], tags: [String]) -> String {
        var lines = ["---"]
        for (key, value) in fields {
            guard let value else { continue }
            lines.append("\(key): \(quotedScalar(value))")
        }
        if tags.isEmpty == false {
            lines.append("tags:")
            lines.append(contentsOf: tags.map { "  - \(quotedScalar($0))" })
        }
        lines.append("---")
        return lines.joined(separator: "\n")
    }
}

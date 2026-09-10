import Foundation

public enum MarkdownAnnotationExporter {
    public static func render(_ bundle: ExportBundle) -> String {
        guard bundle.groups.isEmpty == false else {
            return "# Apple Books export\n\n_No records._\n"
        }
        return "# Apple Books export\n\n" + bundle.groups
            .map { renderPlain(group: $0, headingLevel: 2) }
            .joined(separator: "\n\n") + "\n"
    }

    static func render(_ group: ExportGroup) -> String {
        renderPlain(group: group, headingLevel: 1) + "\n"
    }

    private static func renderPlain(
        group: ExportGroup,
        headingLevel: Int
    ) -> String {
        let source = sourceContext(group)
        var blocks = ["\(String(repeating: "#", count: headingLevel)) \(escapeHeading(source.title))"]
        if let author = source.author {
            blocks.append("**Author:** \(escapeInline(author))")
        }
        blocks.append("**Source:** \(source.kind)")
        if let identity = source.identity {
            blocks.append("**Identity:** \(escapeInline(identity))")
        }
        if let path = source.path {
            blocks.append("**Path:** \(escapeInline(path))")
        }
        if group.records.isEmpty {
            blocks.append("_No records._")
            return blocks.joined(separator: "\n\n")
        }
        blocks.append(contentsOf: group.records.map(formatPlainRecord))
        return blocks.joined(separator: "\n\n")
    }

    private static func formatPlainRecord(_ record: ExportRecord) -> String {
        var blocks = [record.hasNote ? "### Note" : "### Highlight"]
        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let quote = nonEmpty(annotation.selectedText) ?? nonEmpty(annotation.representativeText) {
                blocks.append(blockquote(label: "Quote", text: quote))
            }
            if let note = nonEmpty(annotation.note) {
                blocks.append(blockquote(label: "Note", text: note))
            }
            blocks.append(contentsOf: appleBooksLocation(annotation))
            if let date = annotation.modifiedAt ?? annotation.createdAt {
                blocks.append("**Date:** \(formatDate(date))")
            }
        case let .pdf(_, highlight):
            if let quote = nonEmpty(highlight.text) {
                blocks.append(blockquote(label: "Quote", text: quote))
            }
            if let note = nonEmpty(highlight.note) {
                blocks.append(blockquote(label: "Note", text: note))
            }
            blocks.append("**Page:** \(highlight.page)")
            if let date = highlight.modifiedAt {
                blocks.append("**Date:** \(formatDate(date))")
            }
        }
        if let color = record.presentationColor {
            blocks.append("**Color:** \(color.rawValue)")
        }
        if record.isUnderline {
            blocks.append("**Underline:** true")
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func appleBooksLocation(_ annotation: Annotation) -> [String] {
        if let cfi = annotation.location?.rawCFI {
            if let url = annotation.appleBooksURL {
                return ["**Location:** [\(escapeInline(cfi))](<\(url)>)"]
            }
            return ["**Location:** \(escapeInline(cfi))"]
        }
        return annotation.appleBooksURL.map { ["**Apple Books:** [Open book](<\($0)>)"] } ?? []
    }

    private static func sourceContext(_ group: ExportGroup) -> MarkdownSourceContext {
        switch group.source {
        case let .epubCurrent(book):
            return MarkdownSourceContext(
                title: nonEmpty(book.title) ?? nonEmpty(book.assetID) ?? "Untitled EPUB",
                author: nonEmpty(book.author),
                kind: "EPUB",
                identity: book.assetID,
                path: nil
            )
        case let .epubHistorical(assetID, metadata):
            return MarkdownSourceContext(
                title: metadata.title,
                author: nonEmpty(metadata.author),
                kind: "Historical EPUB",
                identity: assetID,
                path: nil
            )
        case let .epubUnmapped(assetID):
            return MarkdownSourceContext(
                title: "Unmapped EPUB",
                author: nil,
                kind: "Unmapped EPUB",
                identity: assetID,
                path: nil
            )
        case let .pdf(source):
            return MarkdownSourceContext(
                title: source.displayTitle,
                author: source.book.flatMap { nonEmpty($0.author) },
                kind: "PDF",
                identity: source.book?.assetID,
                path: source.fileURL.path
            )
        }
    }

    private static func blockquote(label: String, text: String) -> String {
        let lines = normalizedLines(text)
        return "**\(label):**\n" + lines.map { "> \(escapeInline($0))" }.joined(separator: "\n")
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    private static func escapeHeading(_ text: String) -> String {
        escapeInline(normalizedLines(text).joined(separator: " "))
    }

    private static func escapeInline(_ text: String) -> String {
        escapeMarkdown(normalizedLines(text).joined(separator: " "))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text, text.isEmpty == false else { return nil }
        return text
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let structural = Set("\\`*_{}[]<>()#+!|")
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            if structural.contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
    }
}

private struct MarkdownSourceContext {
    let title: String
    let author: String?
    let kind: String
    let identity: String?
    let path: String?
}

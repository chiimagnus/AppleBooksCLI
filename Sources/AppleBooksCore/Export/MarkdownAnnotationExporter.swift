import Foundation

enum MarkdownAnnotationExporter {
    static func renderAll(_ annotations: [Annotation]) -> String {
        let sorted = annotations.sorted(by: presentationOrder)
        guard sorted.isEmpty == false else {
            return "# Annotations export\n\n_No annotations._\n"
        }

        var output = ["# Annotations export"]
        var index = sorted.startIndex
        while index < sorted.endIndex {
            let assetID = sorted[index].rawAssetID
            let end = sorted[index...].firstIndex { $0.rawAssetID != assetID } ?? sorted.endIndex
            let heading = escapeMarkdown(assetID ?? "(unknown)")
            output += ["", "## \(heading)", ""]
            output.append(sorted[index..<end].map(format).joined(separator: "\n\n---\n\n"))
            index = end
        }
        return output.joined(separator: "\n") + "\n"
    }

    static func render(assetID: String, annotations: [Annotation]) -> String {
        let header = "# Annotations for \(escapeMarkdown(assetID))"
        let sorted = annotations.sorted(by: annotationOrder)
        guard sorted.isEmpty == false else {
            return "\(header)\n\n_No annotations._\n"
        }
        return "\(header)\n\n\(sorted.map(format).joined(separator: "\n\n---\n\n"))\n"
    }

    static func render(_ bundle: ExportBundle) -> String {
        guard bundle.groups.isEmpty == false else {
            return "# Apple Books export\n\n_No records._\n"
        }
        return "# Apple Books export\n\n" + bundle.groups
            .map { render(group: $0, headingLevel: 2) }
            .joined(separator: "\n\n") + "\n"
    }

    static func render(_ group: ExportGroup) -> String {
        render(group: group, headingLevel: 1) + "\n"
    }

    private static func render(group: ExportGroup, headingLevel: Int) -> String {
        let source = groupPresentation(group.source)
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
        blocks.append(contentsOf: group.records.map(formatRecord))
        return blocks.joined(separator: "\n\n")
    }

    private static func formatRecord(_ record: ExportRecord) -> String {
        var blocks = ["### \(presentationKindLabel(record.presentationKind))"]
        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let quote = nonEmpty(annotation.selectedText) ?? nonEmpty(annotation.representativeText) {
                blocks.append(blockquote(label: "Quote", text: quote))
            }
            if let note = nonEmpty(annotation.note) {
                blocks.append(blockquote(label: "Note", text: note))
            }
            if let cfi = annotation.location?.rawCFI {
                blocks.append("**Location:** \(escapeInline(cfi))")
            }
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

    private static func presentationKindLabel(_ kind: ExportPresentationKind) -> String {
        switch kind {
        case .highlight: "Highlight"
        case .note: "Note"
        case .bookmark: "Bookmark"
        }
    }

    private static func groupPresentation(
        _ source: ExportGroupSource
    ) -> (title: String, author: String?, kind: String, identity: String?, path: String?) {
        switch source {
        case let .epubCurrent(book):
            return (
                nonEmpty(book.title) ?? nonEmpty(book.assetID) ?? "Untitled EPUB",
                nonEmpty(book.author),
                "EPUB",
                book.assetID,
                nil
            )
        case let .epubHistorical(assetID, metadata):
            return (metadata.title, nonEmpty(metadata.author), "Historical EPUB", assetID, nil)
        case let .epubUnmapped(assetID):
            return ("Unmapped EPUB", nil, "Unmapped EPUB", assetID, nil)
        case let .pdf(source):
            return (
                source.displayTitle,
                source.book.flatMap { nonEmpty($0.author) },
                "PDF",
                source.book?.assetID,
                source.fileURL.path
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

    private static func presentationOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        switch (lhs.rawAssetID, rhs.rawAssetID) {
        case (nil, nil):
            return annotationOrder(lhs, rhs)
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (left?, right?) where left != right:
            return left < right
        default:
            return annotationOrder(lhs, rhs)
        }
    }

    private static func annotationOrder(_ lhs: Annotation, _ rhs: Annotation) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case (nil, nil):
            return lhs.localPK < rhs.localPK
        case (nil, _):
            return true
        case (_, nil):
            return false
        case let (left?, right?) where left != right:
            return left < right
        default:
            return lhs.localPK < rhs.localPK
        }
    }

    private static func format(_ annotation: Annotation) -> String {
        var blocks: [String] = []
        if let selectedText = annotation.selectedText, selectedText.isEmpty == false {
            let normalized = selectedText.replacingOccurrences(of: "\r\n", with: "\n")
            blocks.append(
                normalized.components(separatedBy: "\n")
                    .map { "> \(escapeMarkdown($0))" }
                    .joined(separator: "\n")
            )
        }
        if let note = annotation.note, note.isEmpty == false {
            blocks.append("**Note:** \(escapeMarkdown(note))")
        }
        return blocks.joined(separator: "\n\n")
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

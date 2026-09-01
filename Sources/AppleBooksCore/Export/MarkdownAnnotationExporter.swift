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

    static func render(_ bundle: ExportBundle, profile: MarkdownProfile = .plain) -> String {
        guard bundle.groups.isEmpty == false else {
            return "# Apple Books export\n\n_No records._\n"
        }
        guard profile.syntax == .obsidian else {
            return "# Apple Books export\n\n" + bundle.groups
                .map { renderPlain(group: $0, headingLevel: 2) }
                .joined(separator: "\n\n") + "\n"
        }

        var blocks: [String] = []
        if profile.options.extendedFrontmatter {
            if bundle.groups.count == 1, let group = bundle.groups.first {
                blocks.append(frontmatter(for: group, profile: profile))
            } else {
                blocks.append(
                    MarkdownYAML.frontmatter(
                        fields: [
                            ("type", "apple-books-export"),
                            ("documents", String(bundle.statistics.documentCount)),
                        ],
                        tags: stableTags(profile.options.customTags)
                    )
                )
            }
        }
        blocks.append("# Apple Books export")
        blocks.append(contentsOf: bundle.groups.map {
            renderObsidian(group: $0, headingLevel: 2, profile: profile, includeFrontmatter: false)
        })
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func render(_ group: ExportGroup, profile: MarkdownProfile = .plain) -> String {
        if profile.syntax == .obsidian {
            return renderObsidian(group: group, headingLevel: 1, profile: profile, includeFrontmatter: true) + "\n"
        }
        return renderPlain(group: group, headingLevel: 1) + "\n"
    }

    private static func renderPlain(group: ExportGroup, headingLevel: Int) -> String {
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

    private static func renderObsidian(
        group: ExportGroup,
        headingLevel: Int,
        profile: MarkdownProfile,
        includeFrontmatter: Bool
    ) -> String {
        let source = sourceContext(group)
        let options = profile.options
        var blocks: [String] = []
        if includeFrontmatter, options.extendedFrontmatter {
            blocks.append(frontmatter(for: group, profile: profile))
        }
        blocks.append("\(String(repeating: "#", count: headingLevel)) \(escapeHeading(source.title))")
        if let author = source.author {
            blocks.append("**Author:** \(renderAuthor(author, options: options))")
        }
        blocks.append("**Source:** \(source.kind)")
        if let identity = source.identity {
            blocks.append("**Identity:** \(escapeInline(identity))")
        }
        if let path = source.path {
            blocks.append("**Path:** \(escapeInline(path))")
        }
        if options.bodyMetadata {
            blocks.append(contentsOf: bodyMetadata(source))
        }
        if options.readingProgress, let progress = source.readingProgressPercent {
            blocks.append("**Reading progress:** \(formatPercent(progress))")
        }
        let tags = tags(for: source, options: options)
        if options.extendedFrontmatter == false, tags.isEmpty == false {
            blocks.append("**Tags:** \(tags.map(escapeInline).joined(separator: ", "))")
        }
        if group.records.isEmpty {
            blocks.append("_No records._")
            return blocks.joined(separator: "\n\n")
        }

        let groups = AnnotationPresentationGroup.make(
            records: group.records,
            groupConsecutiveNullLocationFragments: options.groupConsecutiveNullLocationFragments
        )
        var previousChapter: String?
        let chapterLevel = headingLevel + 1
        let recordLevel = headingLevel + (options.chapterHeadings ? 2 : 1)
        for presentationGroup in groups {
            if options.chapterHeadings,
               let chapter = chapterLabel(for: presentationGroup),
               chapter != previousChapter {
                blocks.append("\(String(repeating: "#", count: chapterLevel)) \(escapeHeading(chapter))")
                previousChapter = chapter
            }
            blocks.append(contentsOf: presentationGroup.members.map {
                formatObsidianRecord($0, headingLevel: recordLevel, source: source, options: options)
            })
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func formatPlainRecord(_ record: ExportRecord) -> String {
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

    private static func formatObsidianRecord(
        _ record: ExportRecord,
        headingLevel: Int,
        source: MarkdownSourceContext,
        options: ObsidianMarkdownOptions
    ) -> String {
        var blocks = ["\(String(repeating: "#", count: headingLevel)) \(presentationKindLabel(record.presentationKind))"]
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
            if options.annotationDates, let date = annotation.modifiedAt ?? annotation.createdAt {
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
            if options.annotationDates, let date = highlight.modifiedAt {
                blocks.append("**Date:** \(formatDate(date))")
            }
        }

        if options.annotationStyle {
            if let style = styleLabel(record) {
                blocks.append("**Style:** \(style)")
            }
            if record.isUnderline {
                blocks.append("**Underline:** true")
            }
        }
        if options.citation, let citation = citation(for: record, source: source) {
            blocks.append(blockquote(label: "Citation", text: citation))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func frontmatter(for group: ExportGroup, profile: MarkdownProfile) -> String {
        let source = sourceContext(group)
        return MarkdownYAML.frontmatter(
            fields: [
                ("type", "apple-books-document"),
                ("title", source.title),
                ("author", source.author),
                ("source", source.kind),
                ("asset_id", source.identity),
                ("path", source.path),
                ("publisher", source.publisher),
                ("year", source.year.map(String.init)),
                ("language", source.language),
                ("isbn", source.isbn),
            ],
            tags: tags(for: source, options: profile.options)
        )
    }

    private static func bodyMetadata(_ source: MarkdownSourceContext) -> [String] {
        var blocks: [String] = []
        if let publisher = source.publisher {
            blocks.append("**Publisher:** \(escapeInline(publisher))")
        }
        if let year = source.year {
            blocks.append("**Year:** \(year)")
        }
        if let language = source.language {
            blocks.append("**Language:** \(escapeInline(language))")
        }
        if let isbn = source.isbn {
            blocks.append("**ISBN:** \(escapeInline(isbn))")
        }
        return blocks
    }

    private static func tags(
        for source: MarkdownSourceContext,
        options: ObsidianMarkdownOptions
    ) -> [String] {
        let sourceTags = options.includeTags ? source.tags : []
        return stableTags(sourceTags + options.customTags)
    }

    private static func stableTags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            value.isEmpty == false && seen.insert(value).inserted
        }
    }

    private static func chapterLabel(for group: AnnotationPresentationGroup) -> String? {
        guard let record = group.locatedMember else { return nil }
        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            return nonEmpty(annotation.location?.chapterID) ?? nonEmpty(annotation.chapterHint)
        case .pdf:
            return nil
        }
    }

    private static func styleLabel(_ record: ExportRecord) -> String? {
        if let color = record.presentationColor {
            return color.rawValue
        }
        if case let .epub(enriched) = record.payload, let rawStyle = enriched.annotation.style {
            return "raw-\(rawStyle)"
        }
        return nil
    }

    private static func citation(for record: ExportRecord, source: MarkdownSourceContext) -> String? {
        var pieces: [String] = []
        if let author = source.author { pieces.append(author) }
        pieces.append(source.title)
        if let publisher = source.publisher { pieces.append(publisher) }
        if let year = source.year { pieces.append(String(year)) }

        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let page = annotation.physicalLocation {
                pieces.append("p. \(page)")
            }
            if let cfi = annotation.location?.rawCFI {
                pieces.append("Location: \(cfi)")
            }
        case let .pdf(_, highlight):
            pieces.append("p. \(highlight.page)")
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: ", ")
    }

    private static func renderAuthor(_ author: String, options: ObsidianMarkdownOptions) -> String {
        guard options.authorLinks else { return escapeInline(author) }
        let component = obsidianSafeComponent(author)
        return "[[Authors/\(component)|\(component)]]"
    }

    private static func obsidianSafeComponent(_ raw: String) -> String {
        var result = ""
        for scalar in raw.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    result += String(format: "%%%02X", byte)
                }
            }
        }
        return result.isEmpty ? "Unknown" : result
    }

    private static func sourceContext(_ group: ExportGroup) -> MarkdownSourceContext {
        switch group.source {
        case let .epubCurrent(book):
            let metadata = group.epubMetadata
            return MarkdownSourceContext(
                title: nonEmpty(book.title) ?? nonEmpty(metadata?.title) ?? nonEmpty(book.assetID) ?? "Untitled EPUB",
                author: nonEmpty(book.author) ?? nonEmpty(metadata?.creator),
                kind: "EPUB",
                identity: book.assetID,
                path: nil,
                publisher: nonEmpty(metadata?.publisher),
                year: book.year,
                language: nonEmpty(book.language) ?? nonEmpty(metadata?.language),
                isbn: nonEmpty(metadata?.isbn),
                readingProgressPercent: book.readingProgressPercent,
                tags: stableTags(([book.genre].compactMap { nonEmpty($0) }) + (metadata?.subjects ?? []))
            )
        case let .epubHistorical(assetID, metadata):
            return MarkdownSourceContext(
                title: metadata.title,
                author: nonEmpty(metadata.author),
                kind: "Historical EPUB",
                identity: assetID,
                path: nil,
                publisher: nil,
                year: nil,
                language: nil,
                isbn: nil,
                readingProgressPercent: nil,
                tags: []
            )
        case let .epubUnmapped(assetID):
            return MarkdownSourceContext(
                title: "Unmapped EPUB",
                author: nil,
                kind: "Unmapped EPUB",
                identity: assetID,
                path: nil,
                publisher: nil,
                year: nil,
                language: nil,
                isbn: nil,
                readingProgressPercent: nil,
                tags: []
            )
        case let .pdf(source):
            return MarkdownSourceContext(
                title: source.displayTitle,
                author: source.book.flatMap { nonEmpty($0.author) },
                kind: "PDF",
                identity: source.book?.assetID,
                path: source.fileURL.path,
                publisher: nil,
                year: source.book?.year,
                language: source.book.flatMap { nonEmpty($0.language) },
                isbn: nil,
                readingProgressPercent: source.book?.readingProgressPercent,
                tags: source.book.flatMap { nonEmpty($0.genre) }.map { [$0] } ?? []
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

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func presentationKindLabel(_ kind: ExportPresentationKind) -> String {
        switch kind {
        case .highlight: "Highlight"
        case .note: "Note"
        case .bookmark: "Bookmark"
        }
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

private struct MarkdownSourceContext {
    let title: String
    let author: String?
    let kind: String
    let identity: String?
    let path: String?
    let publisher: String?
    let year: Int64?
    let language: String?
    let isbn: String?
    let readingProgressPercent: Double?
    let tags: [String]
}

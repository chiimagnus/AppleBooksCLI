import Foundation

enum MarkdownCoverPresentation: Equatable, Sendable {
    case none
    case inlineDataURL(String)
    case file(relativePath: String)
}

struct MarkdownFileMetadata: Equatable, Sendable {
    let stableHash: String
    let exportedAt: Date
}

struct MarkdownRenderContext: Equatable, Sendable {
    var cover: MarkdownCoverPresentation = .none
    var authorLinkTarget: String?
}

public enum MarkdownAnnotationExporter {
    public static func render(
        _ bundle: ExportBundle,
        profile: MarkdownProfile = .plain
    ) -> String {
        render(bundle, profile: profile, contexts: [:], fileMetadata: nil)
    }

    public static func render(
        _ bundle: ExportBundle,
        profile: MarkdownProfile = .plain,
        coverMode: ExportCoverMode
    ) throws -> String {
        switch coverMode {
        case .none:
            return render(bundle, profile: profile)
        case .inline:
            var contexts: [Int: MarkdownRenderContext] = [:]
            for (index, group) in bundle.groups.enumerated() {
                guard let cover = group.epubCover else { continue }
                let media = try ExportCoverMedia.resolve(cover)
                contexts[index] = MarkdownRenderContext(
                    cover: .inlineDataURL(
                        "data:\(media.type);base64,\(cover.data.base64EncodedString())"
                    )
                )
            }
            return render(bundle, profile: profile, contexts: contexts, fileMetadata: nil)
        case .file:
            throw ExportFileWriterError.writeFailed
        }
    }

    static func render(
        _ bundle: ExportBundle,
        profile: MarkdownProfile,
        contexts: [Int: MarkdownRenderContext],
        fileMetadata: MarkdownFileMetadata? = nil
    ) -> String {
        guard bundle.groups.isEmpty == false else {
            return "# Apple Books export\n\n_No records._\n"
        }
        guard profile.syntax == .obsidian else {
            return "# Apple Books export\n\n" + bundle.groups.enumerated()
                .map { index, group in
                    renderPlain(group: group, headingLevel: 2, context: contexts[index] ?? MarkdownRenderContext())
                }
                .joined(separator: "\n\n") + "\n"
        }

        var blocks: [String] = []
        if profile.options.extendedFrontmatter {
            if bundle.groups.count == 1, let group = bundle.groups.first {
                blocks.append(frontmatter(for: group, profile: profile, fileMetadata: fileMetadata))
            } else {
                blocks.append(
                    MarkdownYAML.frontmatter(
                        fields: [
                            ("type", "apple-books-export"),
                            ("documents", String(bundle.statistics.documentCount)),
                            ("last-import-hash", fileMetadata?.stableHash),
                            ("exported_at", fileMetadata.map { formatDate($0.exportedAt) }),
                        ],
                        tags: stableTags(profile.options.customTags)
                    )
                )
            }
        }
        blocks.append("# Apple Books export")
        blocks.append(contentsOf: bundle.groups.enumerated().map { index, group in
            renderObsidian(
                group: group,
                headingLevel: 2,
                profile: profile,
                includeFrontmatter: false,
                context: contexts[index] ?? MarkdownRenderContext(),
                fileMetadata: nil
            )
        })
        return blocks.joined(separator: "\n\n") + "\n"
    }

    static func render(
        _ group: ExportGroup,
        profile: MarkdownProfile = .plain,
        context: MarkdownRenderContext = MarkdownRenderContext(),
        fileMetadata: MarkdownFileMetadata? = nil
    ) -> String {
        if profile.syntax == .obsidian {
            return renderObsidian(
                group: group,
                headingLevel: 1,
                profile: profile,
                includeFrontmatter: true,
                context: context,
                fileMetadata: fileMetadata
            ) + "\n"
        }
        return renderPlain(group: group, headingLevel: 1, context: context) + "\n"
    }

    private static func renderPlain(
        group: ExportGroup,
        headingLevel: Int,
        context: MarkdownRenderContext
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
        if let cover = coverBlock(context.cover) {
            blocks.append(cover)
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
        includeFrontmatter: Bool,
        context: MarkdownRenderContext,
        fileMetadata: MarkdownFileMetadata?
    ) -> String {
        let source = sourceContext(group)
        let options = profile.options
        var blocks: [String] = []
        if includeFrontmatter, options.extendedFrontmatter {
            blocks.append(frontmatter(for: group, profile: profile, fileMetadata: fileMetadata))
        }
        blocks.append("\(String(repeating: "#", count: headingLevel)) \(escapeHeading(source.title))")
        if let author = source.author {
            blocks.append("**Author:** \(renderAuthor(author, options: options, target: context.authorLinkTarget))")
        }
        blocks.append("**Source:** \(source.kind)")
        if let identity = source.identity {
            blocks.append("**Identity:** \(escapeInline(identity))")
        }
        if let path = source.path {
            blocks.append("**Path:** \(escapeInline(path))")
        }
        if let cover = coverBlock(context.cover) {
            blocks.append(cover)
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

    private static func frontmatter(
        for group: ExportGroup,
        profile: MarkdownProfile,
        fileMetadata: MarkdownFileMetadata?
    ) -> String {
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
                ("last-import-hash", fileMetadata?.stableHash),
                ("exported_at", fileMetadata.map { formatDate($0.exportedAt) }),
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

    private static func renderAuthor(
        _ author: String,
        options: ObsidianMarkdownOptions,
        target: String?
    ) -> String {
        guard options.authorLinks else { return escapeInline(author) }
        let component = ExportPathComponent.safe(author, fallback: "Unknown")
        let safeTarget = target ?? "Authors/\(component)"
        return "[[\(safeTarget)|\(component)]]"
    }

    private static func coverBlock(_ presentation: MarkdownCoverPresentation) -> String? {
        switch presentation {
        case .none:
            nil
        case let .inlineDataURL(url):
            "![Cover](\(url))"
        case let .file(relativePath):
            "![Cover](<\(relativePath)>)"
        }
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

import Foundation

enum HTMLExporter {
    static func render(_ bundle: ExportBundle) -> String {
        let sidebar = bundle.groups.enumerated().map { index, group in
            let source = groupPresentation(group.source)
            return "<li><a href=\"#book-\(index)\">\(escapeText(source.title))</a></li>"
        }.joined(separator: "\n")

        let sections = bundle.groups.enumerated().map { index, group in
            render(group: group, index: index)
        }.joined(separator: "\n")

        let content = sections.isEmpty
            ? "<p class=\"empty-state\">No records.</p>"
            : sections

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Apple Books export</title>
        <style>
        :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
        * { box-sizing: border-box; }
        body { margin: 0; line-height: 1.5; }
        .page-header { padding: 1.5rem; border-bottom: 1px solid currentColor; }
        .stats { display: flex; flex-wrap: wrap; gap: 1rem; margin: 0; }
        .stats div { display: flex; gap: .35rem; }
        .layout { display: grid; grid-template-columns: minmax(12rem, 18rem) minmax(0, 1fr); min-height: 100vh; }
        .sidebar { padding: 1rem; border-right: 1px solid currentColor; }
        .sidebar ul { margin: 0; padding-left: 1.25rem; }
        .content { padding: 1.5rem; min-width: 0; }
        .book-section + .book-section { margin-top: 2.5rem; }
        .book-header { padding-bottom: .75rem; border-bottom: 1px solid currentColor; }
        .source-meta { margin: .25rem 0; overflow-wrap: anywhere; }
        .record { padding: 1rem 0; }
        .record + .record { border-top: 1px solid currentColor; }
        .record-text { white-space: pre-wrap; overflow-wrap: anywhere; }
        .record-meta { margin: .25rem 0; overflow-wrap: anywhere; }
        .empty-state { font-style: italic; }
        </style>
        </head>
        <body>
        <header class="page-header">
        <h1>Apple Books export</h1>
        <dl class="stats">
        <div><dt>Documents</dt><dd>\(bundle.statistics.documentCount)</dd></div>
        <div><dt>Records</dt><dd>\(bundle.statistics.recordCount)</dd></div>
        <div><dt>EPUB annotations</dt><dd>\(bundle.statistics.epubAnnotationCount)</dd></div>
        <div><dt>PDF highlights</dt><dd>\(bundle.statistics.pdfHighlightCount)</dd></div>
        </dl>
        </header>
        <div class="layout">
        <aside class="sidebar">
        <nav aria-label="Documents">
        <ul>
        \(sidebar)
        </ul>
        </nav>
        </aside>
        <main class="content">
        \(content)
        </main>
        </div>
        </body>
        </html>
        """ + "\n"
    }

    private static func render(group: ExportGroup, index: Int) -> String {
        let source = groupPresentation(group.source)
        var metadata = ["<p class=\"source-meta\"><strong>Source:</strong> \(source.kind)</p>"]
        if let author = source.author {
            metadata.append("<p class=\"source-meta\"><strong>Author:</strong> \(escapeText(author))</p>")
        }
        if let identity = source.identity {
            metadata.append("<p class=\"source-meta\"><strong>Identity:</strong> \(escapeText(identity))</p>")
        }
        if let path = source.path {
            metadata.append("<p class=\"source-meta\"><strong>Path:</strong> \(escapeText(path))</p>")
        }

        let records: String
        if group.records.isEmpty {
            records = "<p class=\"empty-state\">No records.</p>"
        } else {
            records = group.records.map(renderRecord).joined(separator: "\n")
        }

        return """
        <section class="book-section" id="book-\(index)">
        <header class="book-header">
        <h2>\(escapeText(source.title))</h2>
        \(metadata.joined(separator: "\n"))
        </header>
        \(records)
        </section>
        """
    }

    private static func renderRecord(_ record: ExportRecord) -> String {
        var body: [String] = ["<h3>\(presentationKindLabel(record.presentationKind))</h3>"]
        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let quote = nonEmpty(annotation.selectedText) ?? nonEmpty(annotation.representativeText) {
                body.append("<div class=\"record-text quote\"><strong>Quote:</strong> \(escapeText(quote))</div>")
            }
            if let note = nonEmpty(annotation.note) {
                body.append("<div class=\"record-text note\"><strong>Note:</strong> \(escapeText(note))</div>")
            }
            if let location = annotation.location?.rawCFI {
                body.append("<p class=\"record-meta\"><strong>Location:</strong> \(escapeText(location))</p>")
            }
            if let date = annotation.modifiedAt ?? annotation.createdAt {
                body.append("<p class=\"record-meta\"><strong>Date:</strong> \(formatDate(date))</p>")
            }
        case let .pdf(_, highlight):
            if let quote = nonEmpty(highlight.text) {
                body.append("<div class=\"record-text quote\"><strong>Quote:</strong> \(escapeText(quote))</div>")
            }
            if let note = nonEmpty(highlight.note) {
                body.append("<div class=\"record-text note\"><strong>Note:</strong> \(escapeText(note))</div>")
            }
            body.append("<p class=\"record-meta\"><strong>Page:</strong> \(highlight.page)</p>")
            if let date = highlight.modifiedAt {
                body.append("<p class=\"record-meta\"><strong>Date:</strong> \(formatDate(date))</p>")
            }
        }
        if let color = record.presentationColor {
            body.append("<p class=\"record-meta\"><strong>Color:</strong> \(color.rawValue)</p>")
        }
        if record.isUnderline {
            body.append("<p class=\"record-meta\"><strong>Underline:</strong> true</p>")
        }
        return "<article class=\"record\">\n\(body.joined(separator: "\n"))\n</article>"
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

    private static func presentationKindLabel(_ kind: ExportPresentationKind) -> String {
        switch kind {
        case .highlight: "Highlight"
        case .note: "Note"
        case .bookmark: "Bookmark"
        }
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

    private static func escapeText(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

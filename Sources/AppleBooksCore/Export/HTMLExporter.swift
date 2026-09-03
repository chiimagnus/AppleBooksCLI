import Foundation

public enum HTMLExporter {
    public static func render(_ bundle: ExportBundle) -> String {
        render(groups: bundle.groups, statistics: bundle.statistics)
    }

    public static func renderDocument(_ group: ExportGroup) -> String {
        let count = group.records.count
        let isPDF: Bool
        if case .pdf = group.source { isPDF = true } else { isPDF = false }
        let statistics = ExportStatistics(
            documentCount: 1,
            epubDocumentCount: isPDF ? 0 : 1,
            pdfDocumentCount: isPDF ? 1 : 0,
            recordCount: count,
            epubAnnotationCount: isPDF ? 0 : count,
            pdfHighlightCount: isPDF ? count : 0,
            highlightCount: group.records.count { $0.presentationKind == .highlight },
            noteCount: group.records.count { $0.presentationKind == .note },
            bookmarkCount: group.records.count { $0.presentationKind == .bookmark },
            historicalEPUBAnnotationCount: {
                if case .epubHistorical = group.source { return count }
                return 0
            }(),
            unmappedEPUBAnnotationCount: {
                if case .epubUnmapped = group.source { return count }
                return 0
            }()
        )
        return render(groups: [group], statistics: statistics)
    }

    private static func render(groups: [ExportGroup], statistics: ExportStatistics) -> String {
        let sidebar = groups.enumerated().map { index, group in
            let source = groupPresentation(group.source)
            return "<li><a class=\"sidebar-link\" data-book-token=\"book-\(index)\" href=\"#book-\(index)\">\(escapeText(source.title))</a></li>"
        }.joined(separator: "\n")

        let sections = groups.enumerated().map { index, group in
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
        button, input { font: inherit; }
        .page-header { padding: 1.5rem; border-bottom: 1px solid currentColor; }
        .stats { display: flex; flex-wrap: wrap; gap: 1rem; margin: 0; }
        .stats div { display: flex; gap: .35rem; }
        .toolbar { display: flex; flex-wrap: wrap; gap: .5rem; margin-top: 1rem; align-items: center; }
        .toolbar input { flex: 1 1 18rem; min-width: 0; padding: .45rem .6rem; }
        .toolbar button, .book-toggle, .sidebar-toggle { padding: .4rem .65rem; }
        .sidebar-toggle { display: none; }
        .layout { display: grid; grid-template-columns: minmax(12rem, 18rem) minmax(0, 1fr); min-height: 100vh; }
        .sidebar { padding: 1rem; border-right: 1px solid currentColor; }
        .sidebar ul { margin: 0; padding-left: 1.25rem; }
        .sidebar-link[aria-current="true"] { font-weight: 700; text-decoration-thickness: .16em; }
        .content { padding: 1.5rem; min-width: 0; }
        .book-section + .book-section { margin-top: 2.5rem; }
        .book-header { padding-bottom: .75rem; border-bottom: 1px solid currentColor; }
        .book-header h2 { margin: 0 0 .5rem; overflow-wrap: anywhere; }
        .book-toggle { margin-bottom: .5rem; }
        .source-meta { margin: .25rem 0; overflow-wrap: anywhere; }
        .record { padding: 1rem 0; }
        .record + .record { border-top: 1px solid currentColor; }
        .record-text { white-space: pre-wrap; overflow-wrap: anywhere; }
        .record-meta { margin: .25rem 0; overflow-wrap: anywhere; }
        .empty-state { font-style: italic; }
        [hidden] { display: none !important; }
        @media (max-width: 720px) {
          .sidebar-toggle { display: inline-block; }
          .layout { display: block; }
          .sidebar { display: none; position: fixed; inset: 0 auto 0 0; width: min(82vw, 20rem); overflow: auto; background: Canvas; z-index: 10; box-shadow: 0 0 1rem rgba(0, 0, 0, .25); }
          .sidebar.is-open { display: block; }
          .content { padding: 1rem; }
        }
        @media print {
          .toolbar, .sidebar, .sidebar-toggle, .book-toggle { display: none !important; }
          .layout { display: block; min-height: 0; }
          .content { padding: 0; }
          .book-section { display: block !important; break-inside: avoid; }
          .book-body[hidden] { display: block !important; }
        }
        </style>
        </head>
        <body>
        <header class="page-header">
        <h1>Apple Books export</h1>
        <dl class="stats">
        <div><dt>Documents</dt><dd>\(statistics.documentCount)</dd></div>
        <div><dt>Records</dt><dd>\(statistics.recordCount)</dd></div>
        <div><dt>EPUB annotations</dt><dd>\(statistics.epubAnnotationCount)</dd></div>
        <div><dt>PDF highlights</dt><dd>\(statistics.pdfHighlightCount)</dd></div>
        </dl>
        <div class="toolbar" aria-label="Export controls">
        <button class="sidebar-toggle" type="button" aria-controls="document-sidebar" aria-expanded="false">Documents</button>
        <label for="export-search">Search</label>
        <input id="export-search" type="search" autocomplete="off" placeholder="Search title, author, quote, or note">
        <button id="collapse-all" type="button">Collapse All</button>
        <button id="expand-all" type="button">Expand All</button>
        </div>
        </header>
        <div class="layout">
        <aside class="sidebar" id="document-sidebar">
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
        <script>
        (() => {
          const storageKey = "applebookscli.export.html.v1";
          const sections = Array.from(document.querySelectorAll(".book-section"));
          const sidebar = document.getElementById("document-sidebar");
          const sidebarToggle = document.querySelector(".sidebar-toggle");
          const search = document.getElementById("export-search");
          const links = Array.from(document.querySelectorAll(".sidebar-link"));
          let state = { collapsed: [], sidebarOpen: false };

          try {
            const saved = JSON.parse(localStorage.getItem(storageKey) || "null");
            if (saved && Array.isArray(saved.collapsed) && typeof saved.sidebarOpen === "boolean") {
              state = {
                collapsed: saved.collapsed.filter((token) => /^book-\\d+$/.test(token)),
                sidebarOpen: saved.sidebarOpen
              };
            }
          } catch (_) {}

          const saveState = () => {
            try { localStorage.setItem(storageKey, JSON.stringify(state)); } catch (_) {}
          };

          const setCollapsed = (section, collapsed, persist = true) => {
            const token = section.id;
            const body = section.querySelector(".book-body");
            const button = section.querySelector(".book-toggle");
            if (!body || !button) return;
            body.hidden = collapsed;
            button.setAttribute("aria-expanded", String(!collapsed));
            button.textContent = collapsed ? "Expand" : "Collapse";
            const next = new Set(state.collapsed);
            if (collapsed) next.add(token); else next.delete(token);
            state.collapsed = Array.from(next).sort();
            if (persist) saveState();
          };

          const setSidebarOpen = (open, persist = true) => {
            if (!sidebar || !sidebarToggle) return;
            sidebar.classList.toggle("is-open", open);
            sidebarToggle.setAttribute("aria-expanded", String(open));
            state.sidebarOpen = open;
            if (persist) saveState();
          };

          sections.forEach((section) => {
            setCollapsed(section, state.collapsed.includes(section.id), false);
            section.querySelector(".book-toggle")?.addEventListener("click", () => {
              setCollapsed(section, !section.querySelector(".book-body").hidden);
            });
          });
          setSidebarOpen(state.sidebarOpen, false);

          document.getElementById("collapse-all")?.addEventListener("click", () => {
            sections.forEach((section) => setCollapsed(section, true, false));
            saveState();
          });
          document.getElementById("expand-all")?.addEventListener("click", () => {
            sections.forEach((section) => setCollapsed(section, false, false));
            saveState();
          });

          search?.addEventListener("input", () => {
            const query = search.value.trim().toLowerCase();
            sections.forEach((section) => {
              const matches = query.length === 0 || section.textContent.toLowerCase().includes(query);
              section.hidden = !matches;
              const link = document.querySelector(`.sidebar-link[data-book-token="${section.id}"]`);
              if (link) link.parentElement.hidden = !matches;
            });
          });

          const setActive = (token) => {
            links.forEach((link) => {
              if (link.dataset.bookToken === token) link.setAttribute("aria-current", "true");
              else link.removeAttribute("aria-current");
            });
          };
          links.forEach((link) => link.addEventListener("click", () => {
            setActive(link.dataset.bookToken);
            if (window.matchMedia("(max-width: 720px)").matches) setSidebarOpen(false);
          }));

          if ("IntersectionObserver" in window) {
            const observer = new IntersectionObserver((entries) => {
              const visible = entries.filter((entry) => entry.isIntersecting)
                .sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0];
              if (visible) setActive(visible.target.id);
            }, { rootMargin: "0px 0px -70% 0px" });
            sections.forEach((section) => observer.observe(section));
          }

          sidebarToggle?.addEventListener("click", () => setSidebarOpen(!sidebar.classList.contains("is-open")));
          document.addEventListener("click", (event) => {
            if (!window.matchMedia("(max-width: 720px)").matches || !sidebar?.classList.contains("is-open")) return;
            if (sidebar.contains(event.target) || sidebarToggle?.contains(event.target)) return;
            setSidebarOpen(false);
          });
        })();
        </script>
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
        <button class="book-toggle" type="button" aria-controls="book-body-\(index)" aria-expanded="true">Collapse</button>
        \(metadata.joined(separator: "\n"))
        </header>
        <div class="book-body" id="book-body-\(index)">
        \(records)
        </div>
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
            if let url = annotation.appleBooksURL {
                body.append("<p class=\"record-meta\"><a class=\"apple-books-link\" href=\"\(escapeText(url))\">Open in Apple Books</a></p>")
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

import Foundation

package enum MarkdownAnnotationExporter {
    package static func stream(
        _ bundle: ExportBundle,
        observeBufferedBytes: ((Int) -> Void)? = nil,
        to sink: (Data) throws -> Void
    ) throws {
        try withoutActuallyEscaping(sink) { escapingSink in
            let writer = StreamingMarkdownWriter(sink: escapingSink, observeBufferedBytes: observeBufferedBytes)
            try writer.writeBundle(bundle)
            try writer.finish()
        }
    }

    package static func stream(
        _ group: ExportGroup,
        observeBufferedBytes: ((Int) -> Void)? = nil,
        to sink: (Data) throws -> Void
    ) throws {
        try withoutActuallyEscaping(sink) { escapingSink in
            let writer = StreamingMarkdownWriter(sink: escapingSink, observeBufferedBytes: observeBufferedBytes)
            try writer.writeDocument(group)
            try writer.finish()
        }
    }
}

private final class StreamingMarkdownWriter {
    private let sink: (Data) throws -> Void
    private let observeBufferedBytes: ((Int) -> Void)?
    private var buffer: [UInt8] = []
    private let dateFormatter: ISO8601DateFormatter

    init(sink: @escaping (Data) throws -> Void, observeBufferedBytes: ((Int) -> Void)?) {
        self.sink = sink
        self.observeBufferedBytes = observeBufferedBytes
        buffer.reserveCapacity(ExportFileWriter.maximumChunkBytes)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter = formatter
    }

    func finish() throws { try flush() }

    func writeBundle(_ bundle: ExportBundle) throws {
        if bundle.groups.isEmpty {
            try raw("# Apple Books export\n\n_No records._\n")
            return
        }
        try raw("# Apple Books export\n\n")
        for (index, group) in bundle.groups.enumerated() {
            if index > 0 { try raw("\n\n") }
            try writeGroup(group, headingLevel: 2)
        }
        try raw("\n")
    }

    func writeDocument(_ group: ExportGroup) throws {
        try writeGroup(group, headingLevel: 1)
        try raw("\n")
    }

    private func writeGroup(_ group: ExportGroup, headingLevel: Int) throws {
        let source = sourceContext(group)
        var firstBlock = true
        try block(&firstBlock) {
            try raw(String(repeating: "#", count: headingLevel) + " ")
            try inline(source.title)
        }
        if let author = source.author {
            try block(&firstBlock) {
                try raw("**Author:** ")
                try inline(author)
            }
        }
        try block(&firstBlock) { try raw("**Source:** " + source.kind) }
        if let appleBooksURL = source.appleBooksURL {
            try block(&firstBlock) {
                try raw("**Apple Books:** [Open book](<")
                try raw(appleBooksURL)
                try raw(">)")
            }
        }
        if group.records.isEmpty {
            try block(&firstBlock) { try raw("_No records._") }
            return
        }
        for record in group.records {
            try block(&firstBlock) { try writeRecord(record) }
        }
    }

    private func writeRecord(_ record: ExportRecord) throws {
        var firstBlock = true
        try block(&firstBlock) { try raw(record.hasNote ? "### Note" : "### Highlight") }
        switch record.payload {
        case let .epub(enriched):
            let annotation = enriched.annotation
            if let quote = content(annotation.selectedText) ?? content(annotation.representativeText) {
                try block(&firstBlock) { try blockquote(label: "Quote", text: quote) }
            }
            if let note = content(annotation.note) {
                try block(&firstBlock) { try blockquote(label: "Note", text: note) }
            }
            if let chapter = content(annotation.chapterHint) {
                try block(&firstBlock) {
                    try raw("**Chapter:** ")
                    try inline(chapter)
                }
            }
            if let physicalLocation = annotation.physicalLocation {
                try block(&firstBlock) { try raw("**Location:** \(physicalLocation)") }
            }
            if let createdAt = annotation.createdAt {
                try block(&firstBlock) { try raw("**Created:** " + dateFormatter.string(from: createdAt)) }
            }
            if let modifiedAt = annotation.modifiedAt {
                try block(&firstBlock) { try raw("**Modified:** " + dateFormatter.string(from: modifiedAt)) }
            }
        case let .pdf(_, highlight):
            if let quote = content(highlight.text) {
                try block(&firstBlock) { try blockquote(label: "Quote", text: quote) }
            }
            if let note = content(highlight.note) {
                try block(&firstBlock) { try blockquote(label: "Note", text: note) }
            }
            try block(&firstBlock) { try raw("**Page:** \(highlight.page)") }
            if let modifiedAt = highlight.modifiedAt {
                try block(&firstBlock) { try raw("**Modified:** " + dateFormatter.string(from: modifiedAt)) }
            }
        }
        if let color = record.presentationColor {
            try block(&firstBlock) { try raw("**Color:** " + color.rawValue) }
        }
        if record.isUnderline {
            try block(&firstBlock) { try raw("**Underline:** true") }
        }
    }

    private func sourceContext(_ group: ExportGroup) -> MarkdownSourceContext {
        switch group.source {
        case let .epubCurrent(book):
            return MarkdownSourceContext(
                title: nonEmpty(book.title) ?? "Untitled EPUB",
                author: nonEmpty(book.author),
                kind: "EPUB",
                appleBooksURL: book.assetID.flatMap(Annotation.bookAppleBooksURL(assetID:))
            )
        case let .epubHistorical(assetID, metadata):
            return MarkdownSourceContext(
                title: nonEmpty(metadata.title) ?? "Historical EPUB",
                author: nonEmpty(metadata.author),
                kind: "Historical EPUB",
                appleBooksURL: assetID.flatMap(Annotation.bookAppleBooksURL(assetID:))
            )
        case let .epubUnmapped(assetID):
            return MarkdownSourceContext(
                title: "Unmapped EPUB",
                author: nil,
                kind: "Unmapped EPUB",
                appleBooksURL: assetID.flatMap(Annotation.bookAppleBooksURL(assetID:))
            )
        case let .pdf(source):
            return MarkdownSourceContext(
                title: source.displayTitle,
                author: source.book.flatMap { nonEmpty($0.author) },
                kind: "PDF",
                appleBooksURL: nil
            )
        }
    }

    private func block(_ first: inout Bool, body: () throws -> Void) throws {
        if first { first = false } else { try raw("\n\n") }
        try body()
    }

    private func blockquote(label: String, text: String) throws {
        try raw("**\(label):**\n> ")
        var pendingCR = false
        for byte in text.utf8 {
            if pendingCR {
                if byte == 0x0a {
                    try raw("\n> ")
                    pendingCR = false
                    continue
                }
                try raw("\n> ")
                pendingCR = false
            }
            if byte == 0x0d {
                pendingCR = true
            } else if byte == 0x0a {
                try raw("\n> ")
            } else {
                try escaped(byte)
            }
        }
        if pendingCR { try raw("\n> ") }
    }

    private func inline(_ text: String) throws {
        var pendingCR = false
        for byte in text.utf8 {
            if pendingCR {
                if byte == 0x0a {
                    try appendByte(0x20)
                    pendingCR = false
                    continue
                }
                try appendByte(0x20)
                pendingCR = false
            }
            if byte == 0x0d {
                pendingCR = true
            } else if byte == 0x0a {
                try appendByte(0x20)
            } else {
                try escaped(byte)
            }
        }
        if pendingCR { try appendByte(0x20) }
    }

    private func escaped(_ byte: UInt8) throws {
        switch byte {
        case 0x5c, 0x60, 0x2a, 0x5f, 0x7b, 0x7d, 0x5b, 0x5d, 0x3c, 0x3e,
             0x28, 0x29, 0x23, 0x2b, 0x21, 0x7c:
            try appendByte(0x5c)
        default:
            break
        }
        try appendByte(byte)
    }

    private func content(_ text: String?) -> String? {
        guard AnnotationContentSemantics.hasContent(text) else { return nil }
        return text
    }

    private func nonEmpty(_ text: String?) -> String? {
        guard let text, text.isEmpty == false else { return nil }
        return text
    }

    private func raw(_ text: String) throws {
        for byte in text.utf8 { try appendByte(byte) }
    }

    private func appendByte(_ byte: UInt8) throws {
        if buffer.count == ExportFileWriter.maximumChunkBytes { try flush() }
        buffer.append(byte)
    }

    private func flush() throws {
        guard buffer.isEmpty == false else { return }
        observeBufferedBytes?(buffer.count)
        try sink(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}

private struct MarkdownSourceContext {
    let title: String
    let author: String?
    let kind: String
    let appleBooksURL: String?
}

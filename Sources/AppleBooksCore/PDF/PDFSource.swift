import Foundation

public enum PDFSourceProvenance: String, Equatable, Sendable {
    case library
    case fallback
    case explicit
}

public struct PDFSource: Equatable, Sendable {
    public let fileURL: URL
    public let book: Book?
    public let bookSummary: BookSummary?
    public let displayTitle: String
    public let provenance: PDFSourceProvenance

    init(fileURL: URL, book: Book?, provenance: PDFSourceProvenance? = nil) {
        self.fileURL = fileURL
        self.book = book
        bookSummary = nil
        self.provenance = provenance ?? (book == nil ? .fallback : .library)
        if let title = book?.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            displayTitle = title
        } else {
            displayTitle = fileURL.deletingPathExtension().lastPathComponent
        }
    }

    package init(fileURL: URL, bookSummary: BookSummary?, provenance: PDFSourceProvenance) {
        self.fileURL = fileURL
        book = nil
        self.bookSummary = bookSummary
        self.provenance = provenance
        if let title = bookSummary?.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            displayTitle = title
        } else {
            displayTitle = fileURL.deletingPathExtension().lastPathComponent
        }
    }
}

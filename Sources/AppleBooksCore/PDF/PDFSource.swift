import Foundation

public struct PDFSource: Equatable, Sendable {
    public let fileURL: URL
    public let book: Book?
    public let displayTitle: String

    init(fileURL: URL, book: Book?) {
        self.fileURL = fileURL
        self.book = book
        if let title = book?.title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            displayTitle = title
        } else {
            displayTitle = fileURL.deletingPathExtension().lastPathComponent
        }
    }
}

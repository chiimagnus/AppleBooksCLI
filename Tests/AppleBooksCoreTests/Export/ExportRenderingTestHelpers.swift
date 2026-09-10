import Foundation
@testable import AppleBooksCore

func renderJSON(_ bundle: ExportBundle, exportedAt: Date) throws -> Data {
    var data = Data()
    try JSONExporter.stream(bundle, exportedAt: exportedAt) { data.append($0) }
    return data
}

func renderDocumentJSON(
    _ group: ExportGroup,
    from bundle: ExportBundle,
    exportedAt: Date
) throws -> Data {
    var data = Data()
    try JSONExporter.streamDocument(group, from: bundle, exportedAt: exportedAt) { data.append($0) }
    return data
}

func renderMarkdown(_ bundle: ExportBundle) -> String {
    var data = Data()
    try! MarkdownAnnotationExporter.stream(bundle) { data.append($0) }
    return String(decoding: data, as: UTF8.self)
}

func renderMarkdown(_ group: ExportGroup) -> String {
    var data = Data()
    try! MarkdownAnnotationExporter.stream(group) { data.append($0) }
    return String(decoding: data, as: UTF8.self)
}

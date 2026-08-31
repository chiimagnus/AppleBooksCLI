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

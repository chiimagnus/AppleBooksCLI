import Foundation

public enum OverwritePolicy: String, Equatable, Sendable {
    case never
    case smart
    case always
}

enum ExportPathComponent {
    static let maximumUTF8Bytes = 120

    static func safe(_ raw: String, fallback: String = "untitled") -> String {
        let scalars = Array(raw.unicodeScalars)
        var output = ""
        var byteCount = 0

        for (index, scalar) in scalars.enumerated() {
            let isEdgeSpace = scalar == " " && (index == scalars.startIndex || index == scalars.index(before: scalars.endIndex))
            let segment: String
            if !isEdgeSpace,
               CharacterSet.alphanumerics.contains(scalar) || scalar == " " || scalar == "-" || scalar == "_" {
                segment = String(scalar)
            } else {
                segment = String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
            let segmentBytes = segment.lengthOfBytes(using: .utf8)
            guard byteCount + segmentBytes <= maximumUTF8Bytes else { break }
            output += segment
            byteCount += segmentBytes
        }

        return output.isEmpty ? fallback : output
    }

    static func fileName(derivedFrom raw: String, extension fileExtension: String) -> String {
        "\(safe(raw)).\(fileExtension)"
    }
}

struct ExportFilenameAllocator {
    private var used = Set<String>()

    mutating func allocate(derivedFrom raw: String, extension fileExtension: String) -> String {
        let base = ExportPathComponent.safe(raw)
        var candidate = "\(base).\(fileExtension)"
        var suffix = 2
        while used.insert(candidate).inserted == false {
            candidate = "\(base)-\(suffix).\(fileExtension)"
            suffix += 1
        }
        return candidate
    }
}

import Foundation

public enum OverwritePolicy: String, Equatable, Sendable {
    case never
    case always
}

enum ExportPathComponent {
    static let maximumUTF8Bytes = 120

    static func safe(
        _ raw: String,
        fallback: String = "untitled",
        maximumUTF8Bytes: Int = maximumUTF8Bytes,
        observeRetainedUTF8Bytes: ((Int) -> Void)? = nil
    ) -> String {
        var output = ""
        var byteCount = 0

        for scalar in raw.unicodeScalars {
            let segment: String
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                segment = String(scalar)
            } else {
                segment = String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }
            let segmentBytes = segment.lengthOfBytes(using: .utf8)
            guard byteCount + segmentBytes <= maximumUTF8Bytes else { break }
            output += segment
            byteCount += segmentBytes
            observeRetainedUTF8Bytes?(byteCount)
        }

        return output.isEmpty ? fallback : output
    }
}

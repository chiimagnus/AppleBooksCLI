import Foundation

enum AnnotationContentSemantics {
    private static let asciiWhitespace: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d]

    static func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.utf8.contains { asciiWhitespace.contains($0) == false }
    }

    static func hasContentSQL(_ expression: String) -> String {
        """
        (typeof(\(expression)) = 'text' AND
         length(replace(replace(replace(replace(\(expression), ' ', ''), char(9), ''), char(10), ''), char(13), '')) > 0)
        """
    }

    static func underline(storageValue: Int64?) -> Bool {
        storageValue == 1
    }

    static func underlineSQL(_ expression: String) -> String {
        "(typeof(\(expression)) = 'integer' AND \(expression) = 1)"
    }
}

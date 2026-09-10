import Foundation

package enum AnnotationContextError: Error, Equatable, Sendable {
    case invalidWindow
    case assetIdentityUnavailable
    case currentBookUnavailable
    case currentBookAmbiguous
    case contentPathUnavailable
    case chapterUnavailable
    case anchorUnavailable
    case anchorTooLarge
    case anchorNotFound
}

package struct SemanticAnnotationContextResult: Equatable, Sendable {
    package let annotationLocalPK: Int64
    package let annotationUUID: String?
    package let context: AnnotationContext

    package init(annotationLocalPK: Int64, annotationUUID: String?, context: AnnotationContext) {
        self.annotationLocalPK = annotationLocalPK
        self.annotationUUID = annotationUUID
        self.context = context
    }
}

package struct AnnotationContext: Equatable, Sendable {
    package let before: String
    package let matched: String
    package let after: String
    package let leadingTruncated: Bool
    package let trailingTruncated: Bool
}

enum AnnotationContextMatcher {
    static func match(
        chapterText: String,
        anchor: String,
        charsBefore: Int,
        charsAfter: Int
    ) throws -> AnnotationContext {
        guard charsBefore >= 0, charsAfter >= 0 else {
            throw AnnotationContextError.invalidWindow
        }
        let tokens = anchor.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.isEmpty == false else {
            throw AnnotationContextError.anchorUnavailable
        }
        let pattern = tokens.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        let expression = try NSRegularExpression(pattern: pattern)
        let whole = NSRange(chapterText.startIndex..<chapterText.endIndex, in: chapterText)
        guard let result = expression.firstMatch(in: chapterText, range: whole),
              let matchRange = Range(result.range, in: chapterText) else {
            throw AnnotationContextError.anchorNotFound
        }
        return snapWindow(
            chapterText,
            matchRange: matchRange,
            charsBefore: charsBefore,
            charsAfter: charsAfter
        )
    }

    private static func snapWindow(
        _ text: String,
        matchRange: Range<String.Index>,
        charsBefore: Int,
        charsAfter: Int
    ) -> AnnotationContext {
        let rawStart = text.index(matchRange.lowerBound, offsetBy: -charsBefore, limitedBy: text.startIndex) ?? text.startIndex
        let rawEnd = text.index(matchRange.upperBound, offsetBy: charsAfter, limitedBy: text.endIndex) ?? text.endIndex

        var start = rawStart
        if rawStart > text.startIndex,
           let whitespace = text[rawStart..<matchRange.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: whitespace)
        }

        var end = rawEnd
        if rawEnd < text.endIndex,
           let whitespace = text[matchRange.upperBound..<rawEnd].lastIndex(where: \.isWhitespace) {
            end = whitespace
        }

        return AnnotationContext(
            before: String(text[start..<matchRange.lowerBound]),
            matched: String(text[matchRange]),
            after: String(text[matchRange.upperBound..<end]),
            leadingTruncated: start > text.startIndex,
            trailingTruncated: end < text.endIndex
        )
    }
}

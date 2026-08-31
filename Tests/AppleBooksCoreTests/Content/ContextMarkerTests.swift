import Testing
@testable import AppleBooksCore

@Suite("ContextMarkerTests")
struct ContextMarkerTests {
    @Test
    func marksExactlyTheCanonicalFirstMatchWithoutSearchingAgain() throws {
        let context = try AnnotationContextMatcher.match(
            chapterText: "before alpha beta middle alpha beta after",
            anchor: "alpha beta",
            charsBefore: 20,
            charsAfter: 30
        )

        let canonical = context.text
        let presentation = context.markedPresentation
        #expect(presentation.matched)
        #expect(presentation.text.contains("«alpha beta»"))
        #expect(presentation.text.filter { $0 == "«" }.count == 1)
        #expect(presentation.text.hasSuffix("alpha beta after"))
        #expect(context.text == canonical)
    }

    @Test
    func preservesMatchedSourceWhitespaceInsideMarker() throws {
        let context = try AnnotationContextMatcher.match(
            chapterText: "left alpha\n\tbeta right",
            anchor: "alpha beta",
            charsBefore: 20,
            charsAfter: 20
        )

        #expect(context.matched == "alpha\n\tbeta")
        #expect(context.markedPresentation.text.contains("«alpha\n\tbeta»"))
        #expect(context.markedPresentation.matched)
    }

    @Test
    func missingCanonicalMatchLeavesWindowUntouchedAndReportsFalse() {
        let context = AnnotationContext(
            before: "before ",
            matched: "",
            after: "after",
            leadingTruncated: true,
            trailingTruncated: true
        )

        #expect(context.markedPresentation == AnnotationContextPresentation(
            text: context.text,
            matched: false
        ))
    }
}

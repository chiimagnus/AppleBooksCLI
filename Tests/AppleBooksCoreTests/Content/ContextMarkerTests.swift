import Testing
@testable import AppleBooksCore

@Suite("ContextMatcherTests")
struct ContextMatcherTests {
    @Test
    func keepsFirstCanonicalMatchWithoutSearchingAgain() throws {
        let context = try AnnotationContextMatcher.match(
            chapterText: "before alpha beta middle alpha beta after",
            anchor: "alpha beta",
            charsBefore: 20,
            charsAfter: 30
        )

        #expect(context.before.hasSuffix("before "))
        #expect(context.matched == "alpha beta")
        #expect(context.after.contains("middle alpha beta after"))
    }

    @Test
    func preservesMatchedSourceWhitespace() throws {
        let context = try AnnotationContextMatcher.match(
            chapterText: "left alpha\n\tbeta right",
            anchor: "alpha beta",
            charsBefore: 20,
            charsAfter: 20
        )

        #expect(context.matched == "alpha\n\tbeta")
    }
}

import Testing
@testable import AppleBooksCore

@Suite("AnnotationContextAnchorMissTests")
struct AnnotationContextAnchorMissTests {
    @Test
    func emptyOrWhitespaceAnchorIsUnavailable() {
        #expect(throws: AnnotationContextError.anchorUnavailable) {
            _ = try AnnotationContextMatcher.match(chapterText: "chapter opening", anchor: "", charsBefore: 10, charsAfter: 10)
        }
        #expect(throws: AnnotationContextError.anchorUnavailable) {
            _ = try AnnotationContextMatcher.match(chapterText: "chapter opening", anchor: " \n\t ", charsBefore: 10, charsAfter: 10)
        }
    }

    @Test
    func missingAnchorNeverReturnsChapterOpening() {
        #expect(throws: AnnotationContextError.anchorNotFound) {
            _ = try AnnotationContextMatcher.match(chapterText: "chapter opening that must not leak", anchor: "absent", charsBefore: 10, charsAfter: 10)
        }
    }

    @Test
    func regexMetacharactersAreLiteralAndFirstDuplicateWins() throws {
        let chapter = "prefix a+b [x] first middle a+b [x] second suffix"
        let context = try AnnotationContextMatcher.match(
            chapterText: chapter,
            anchor: "a+b [x]",
            charsBefore: 7,
            charsAfter: 7
        )
        #expect(context.matched == "a+b [x]")
        #expect(context.before.contains("prefix"))
        #expect(context.after.contains("first"))
        #expect(context.after.contains("second") == false)
    }

    @Test
    func flexibleWhitespaceMatchesParagraphBreakWithoutFlatteningSource() throws {
        let context = try AnnotationContextMatcher.match(
            chapterText: "before token\n\nnext after",
            anchor: "token next",
            charsBefore: 20,
            charsAfter: 20
        )
        #expect(context.matched == "token\n\nnext")
        #expect(context.text.contains("\n\n"))
    }

    @Test
    func graphemeWindowDoesNotSplitCJKOrEmoji() throws {
        let chapter = "甲乙😀丙丁 高亮 文本 戊己👨‍👩‍👧‍👦庚辛"
        let context = try AnnotationContextMatcher.match(
            chapterText: chapter,
            anchor: "高亮 文本",
            charsBefore: 4,
            charsAfter: 4
        )
        #expect(context.matched == "高亮 文本")
        #expect(context.before.contains("�") == false)
        #expect(context.after.contains("�") == false)
        #expect(context.text.contains("高亮 文本"))
    }

    @Test
    func negativeWindowIsRejected() {
        #expect(throws: AnnotationContextError.invalidWindow) {
            _ = try AnnotationContextMatcher.match(chapterText: "text", anchor: "text", charsBefore: -1, charsAfter: 0)
        }
    }
}

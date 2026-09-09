import Testing
@testable import AppleBooksCore

@Suite("LocationTests")
struct LocationTests {
    @Test
    func extractsLastSpineHintAndLeafCharacterRange() {
        let location = Location(rawCFI: "epubcfi(/6/8[item5]!/4/2[pgepubid00005]/18/1,:629,:691)")
        #expect(location.rawCFI == "epubcfi(/6/8[item5]!/4/2[pgepubid00005]/18/1,:629,:691)")
        #expect(location.chapterID == "item5")
        #expect(location.characterRange == .init(start: 629, end: 691))
    }

    @Test
    func usesLastBracketHintFromSpineOnly() {
        let location = Location(rawCFI: "epubcfi(/6/2[first]/8[last]!/4/2[content],:1,:2)")
        #expect(location.chapterID == "last")
        #expect(location.characterRange == .init(start: 1, end: 2))
    }

    @Test
    func malformedOrPartialCfiIsDiagnosticOnly() {
        let malformed = Location(rawCFI: "not-a-cfi")
        #expect(malformed.chapterID == nil)
        #expect(malformed.characterRange == nil)

        let noHints = Location(rawCFI: "epubcfi(/6/8!/4/2)")
        #expect(noHints.chapterID == nil)
        #expect(noHints.characterRange == nil)

        let unclosedAssertion = Location(rawCFI: "epubcfi(/6/2[unterminated!/4/2,:1,:2)")
        #expect(unclosedAssertion.chapterID == nil)
        #expect(unclosedAssertion.characterRange == nil)

        let hugeInteger = Location(rawCFI: "epubcfi(/6/2[ch]!/4/2,:999999999999999999999999999999999999,:2)")
        #expect(hugeInteger.chapterID == "ch")
        #expect(hugeInteger.characterRange == nil)
    }

    @Test
    func structuralBudgetIsExactAndOversizeRawValueStaysLossless() throws {
        let below = try cfi(totalUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes - 1)
        let boundary = try cfi(totalUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes)
        let over = try cfi(totalUTF8Bytes: CFIResourcePolicy.maximumStructuralBytes + 1)

        #expect(CFIResourcePolicy.allowsStructuralParsing(below))
        #expect(CFIResourcePolicy.allowsStructuralParsing(boundary))
        #expect(CFIResourcePolicy.allowsStructuralParsing(over) == false)

        let belowLocation = Location(rawCFI: below)
        #expect(belowLocation.rawCFI == below)
        #expect(belowLocation.characterRange == .init(start: 1, end: 2))

        let boundaryLocation = Location(rawCFI: boundary)
        #expect(boundaryLocation.rawCFI == boundary)
        #expect(boundaryLocation.characterRange == .init(start: 1, end: 2))

        let oversizedLocation = Location(rawCFI: over)
        #expect(oversizedLocation.rawCFI == over)
        #expect(oversizedLocation.chapterID == nil)
        #expect(oversizedLocation.characterRange == nil)
        #expect(Annotation.appleBooksURL(rawAssetID: "book", rawCFI: over) == "ibooks://assetid/book")
    }

    @Test
    func parserHandlesUnicodeAssertionsAndManySegmentsWithoutSplitArrays() {
        let unicode = Location(rawCFI: "epubcfi(/6/2[章节📚]!/4/2,:7,:9)")
        #expect(unicode.chapterID == "章节📚")
        #expect(unicode.characterRange == .init(start: 7, end: 9))

        let manySegments = "epubcfi(" + String(repeating: "/1", count: 20_000) + ")"
        let parsed = CFIStructureParser.parse(manySegments, collectReadingNumbers: true)
        #expect(parsed?.readingNumbers?.count == 20_000)
        #expect(parsed?.readingNumbers?.first == 1)
        #expect(parsed?.readingNumbers?.last == 1)
    }

    private func cfi(totalUTF8Bytes: Int) throws -> String {
        let prefix = "epubcfi(/6/2["
        let suffix = "]!/4/2,:1,:2)"
        let fixedBytes = prefix.utf8.count + suffix.utf8.count
        let fillerCount = totalUTF8Bytes - fixedBytes
        #expect(fillerCount >= 1)
        let value = prefix + String(repeating: "x", count: fillerCount) + suffix
        #expect(value.utf8.count == totalUTF8Bytes)
        return value
    }
}

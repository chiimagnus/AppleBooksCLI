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
    }
}

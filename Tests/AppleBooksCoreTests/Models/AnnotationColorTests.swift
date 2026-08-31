import Testing
@testable import AppleBooksCore

@Suite("AnnotationColorTests")
struct AnnotationColorTests {
    @Test
    func mapsExactlyFiveNamedColors() throws {
        #expect(try AnnotationColor(name: "GREEN") == .green)
        #expect(try AnnotationColor(name: "blue") == .blue)
        #expect(try AnnotationColor(name: "Yellow") == .yellow)
        #expect(try AnnotationColor(name: "pink") == .pink)
        #expect(try AnnotationColor(name: "PURPLE") == .purple)
        #expect(AnnotationColor.allCases.map(\.rawValue) == [1, 2, 3, 4, 5])
    }

    @Test
    func unknownColorFailsWithoutEchoingInput() {
        #expect(throws: AnnotationQueryInputError.unknownColor) {
            _ = try AnnotationColor(name: "secret-user-value")
        }
        #expect(throws: AnnotationQueryInputError.unknownColor) {
            _ = try AnnotationColor(name: "绿")
        }
    }
}

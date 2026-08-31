import Foundation
import SQLite3
import Testing
@testable import AppleBooksCore

@Test
func bootstrap() {
    #expect(AppleBooksCore.productName == "AppleBooksCLI")
}

@Test
func sqliteRuntimeIsAvailable() {
    #expect(String(cString: sqlite3_libversion()).isEmpty == false)
}

@Test
func appleEpochRoundTrips() {
    let appleEpoch = Date(timeIntervalSinceReferenceDate: 0)
    #expect(appleEpoch.timeIntervalSince1970 == 978_307_200)

    let sample: TimeInterval = 123_456_789
    #expect(Date(timeIntervalSinceReferenceDate: sample).timeIntervalSinceReferenceDate == sample)
}

@Test
func fixtureProvenanceIsLocatable() throws {
    let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/fixture-provenance.txt")
    let provenance = try String(contentsOf: fixtureURL, encoding: .utf8)
    #expect(provenance.contains("synthetic data"))
}

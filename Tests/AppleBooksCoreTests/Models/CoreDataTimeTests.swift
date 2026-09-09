import Foundation
import Testing
@testable import AppleBooksCore

@Suite("CoreDataTimeTests")
struct CoreDataTimeTests {
    @Test
    func appleEpochMatchesKnownUnixInstant() {
        let epoch = CoreDataTime.date(from: 0)
        #expect(epoch?.timeIntervalSince1970 == 978_307_200)
        #expect(CoreDataTime.seconds(from: epoch) == 0)
    }

    @Test
    func arbitraryTimestampRoundTripsWithoutTimezoneFormatting() {
        let seconds = 725_846_400.125
        let date = CoreDataTime.date(from: seconds)
        #expect(CoreDataTime.seconds(from: date) == seconds)
        #expect(CoreDataTime.date(from: nil) == nil)
        #expect(CoreDataTime.seconds(from: nil) == nil)
    }

    @Test
    func canonicalMachineDateRangeRejectsNonFiniteAndOutOfYearRangeValues() {
        #expect(CoreDataTime.date(from: .infinity) == nil)
        #expect(CoreDataTime.date(from: -.infinity) == nil)
        #expect(CoreDataTime.date(from: .nan) == nil)
        #expect(CoreDataTime.date(from: CoreDataTime.minimumSeconds) != nil)
        #expect(CoreDataTime.date(from: CoreDataTime.minimumSeconds.nextDown) == nil)
        #expect(CoreDataTime.date(from: CoreDataTime.maximumSecondsExclusive.nextDown) != nil)
        #expect(CoreDataTime.date(from: CoreDataTime.maximumSecondsExclusive) == nil)

        #expect(CoreDataTime.seconds(from: Date(timeIntervalSince1970: CoreDataTime.minimumUnixSeconds)) != nil)
        #expect(CoreDataTime.seconds(from: Date(timeIntervalSince1970: CoreDataTime.minimumUnixSeconds.nextDown)) == nil)
        #expect(CoreDataTime.seconds(from: Date(timeIntervalSince1970: CoreDataTime.maximumUnixSecondsExclusive.nextDown)) != nil)
        #expect(CoreDataTime.seconds(from: Date(timeIntervalSince1970: CoreDataTime.maximumUnixSecondsExclusive)) == nil)
        #expect(CoreDataTime.seconds(from: Date(timeIntervalSince1970: .infinity)) == nil)
    }

    @Test
    func semanticRealOnlyPublishesFiniteProgressPercent() {
        #expect(SemanticSQLiteReal.finite(.infinity) == nil)
        #expect(SemanticSQLiteReal.finite(-.infinity) == nil)
        #expect(SemanticSQLiteReal.readingProgressPercent(.nan) == nil)
        #expect(SemanticSQLiteReal.readingProgressPercent(-0.5) == 0)
        #expect(SemanticSQLiteReal.readingProgressPercent(0.25) == 25)
        #expect(SemanticSQLiteReal.readingProgressPercent(2) == 100)
        #expect(SemanticSQLiteReal.readingProgressPercent(.greatestFiniteMagnitude) == 100)
    }
}

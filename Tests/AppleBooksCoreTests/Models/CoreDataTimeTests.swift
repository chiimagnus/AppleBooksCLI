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
}

import Testing
@testable import RemanenceCore

@Suite struct TimeTextTests {
    @Test func clockUnderAndOverAnHour() {
        #expect(TimeText.clock(0) == "0:00")
        #expect(TimeText.clock(42) == "0:42")
        #expect(TimeText.clock(245) == "4:05")
        #expect(TimeText.clock(3599.9) == "59:59")
        #expect(TimeText.clock(3600) == "1:00:00")
        #expect(TimeText.clock(3729) == "1:02:09")
    }

    @Test func longUnderAndOverAnHour() {
        #expect(TimeText.long(0) == "0 min")
        #expect(TimeText.long(59) == "0 min")
        #expect(TimeText.long(12 * 60) == "12 min")
        #expect(TimeText.long(3599) == "59 min")
        #expect(TimeText.long(3600) == "1 hr 0 min")
        #expect(TimeText.long(7 * 3600 + 55 * 60) == "7 hr 55 min")
    }

    @Test func preciseUnderAndOverAnHour() {
        #expect(TimeText.precise(0) == "0:00.0")
        #expect(TimeText.precise(34) == "0:34.0")
        #expect(TimeText.precise(724.3) == "12:04.3")
        #expect(TimeText.precise(3729.5) == "1:02:09.5")
    }

    @Test func preciseRoundsRatherThanCutting() {
        #expect(TimeText.precise(1234.0) == "20:34.0")
        // Float error just below the value must not read as 20:33.9.
        #expect(TimeText.precise(1233.9999999999) == "20:34.0")
        #expect(TimeText.precise(59.96) == "1:00.0")
        #expect(TimeText.precise(3599.96) == "1:00:00.0")
    }

    @Test func timecodeAlwaysShowsHours() {
        #expect(TimeText.timecode(0) == "00:00:00")
        #expect(TimeText.timecode(78) == "00:01:18")
        #expect(TimeText.timecode(78.99) == "00:01:18")
        #expect(TimeText.timecode(3729) == "01:02:09")
    }

    @Test func timecodePastNinetyNineMinutes() {
        #expect(TimeText.timecode(99 * 60 + 59) == "01:39:59")
        #expect(TimeText.timecode(100 * 60) == "01:40:00")
        #expect(TimeText.timecode(125 * 60 + 7) == "02:05:07")
    }

    @Test func hundredthsUnderAndOverAnHour() {
        #expect(TimeText.hundredths(0) == "0:00.00")
        #expect(TimeText.hundredths(0.48) == "0:00.48")
        #expect(TimeText.hundredths(102.5) == "1:42.50")
        #expect(TimeText.hundredths(3729.25) == "1:02:09.25")
    }

    @Test func hundredthsRounding() {
        #expect(TimeText.hundredths(0.474) == "0:00.47")
        #expect(TimeText.hundredths(0.476) == "0:00.48")
        // 0.29 is stored as slightly less than 0.29.
        #expect(TimeText.hundredths(0.29) == "0:00.29")
        #expect(TimeText.hundredths(59.999) == "1:00.00")
        #expect(TimeText.hundredths(3599.999) == "1:00:00.00")
    }

    @Test(arguments: [-90.0, -0.04, -.infinity, .infinity, .nan])
    func negativeAndNonFiniteReadAsZero(seconds: Double) {
        #expect(TimeText.clock(seconds) == "0:00")
        #expect(TimeText.long(seconds) == "0 min")
        #expect(TimeText.precise(seconds) == "0:00.0")
        #expect(TimeText.timecode(seconds) == "00:00:00")
        #expect(TimeText.hundredths(seconds) == "0:00.00")
    }
}

import Testing
@testable import OrbitCore

@Suite struct TimeFormatTests {
    @Test func times() {
        #expect(TimeFormat.string(0) == "0:00.00")
        #expect(TimeFormat.string(5.41) == "0:05.41")
        #expect(TimeFormat.string(3725.5) == "1:02:05.50")
    }

    @Test func minutesRollOver() {
        #expect(TimeFormat.string(59.99) == "0:59.99")
        #expect(TimeFormat.string(60) == "1:00.00")
        #expect(TimeFormat.string(754.07) == "12:34.07")
    }

    @Test func hourBoundary() {
        #expect(TimeFormat.string(3599.99) == "59:59.99")
        #expect(TimeFormat.string(3600) == "1:00:00.00")
    }

    @Test func roundsToTheNearestCentisecond() {
        #expect(TimeFormat.string(1.004) == "0:01.00")
        #expect(TimeFormat.string(1.006) == "0:01.01")
        // Rounding up must carry into the seconds, not print ".100".
        #expect(TimeFormat.string(59.996) == "1:00.00")
    }

    @Test func negativeAndNonFiniteShowZero() {
        #expect(TimeFormat.string(-3) == "0:00.00")
        #expect(TimeFormat.string(.nan) == "0:00.00")
        #expect(TimeFormat.string(.infinity) == "0:00.00")
    }
}

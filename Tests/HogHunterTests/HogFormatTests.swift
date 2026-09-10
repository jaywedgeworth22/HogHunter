import XCTest

@testable import HogHunter

/// Covers `HogFormat`.  Rewritten for the 1.1 formatter: `cpu` now switches
/// from one decimal to an integer at 100%, not at 10%, matching Activity
/// Monitor's own display.
final class HogFormatTests: XCTestCase {

    // MARK: - HogFormat.cpu(_:)

    func testCpuBelowOneHundredShowsOneDecimal() {
        XCTAssertEqual(HogFormat.cpu(0.0), "0.0%")
        XCTAssertEqual(HogFormat.cpu(4.2), "4.2%")
        XCTAssertEqual(HogFormat.cpu(99.6), "99.6%")
    }

    func testCpuAtOrAboveOneHundredShowsInteger() {
        XCTAssertEqual(HogFormat.cpu(100.0), "100%")
        XCTAssertEqual(HogFormat.cpu(312.0), "312%")
    }

    func testCpuNegativeOrNaNClampsToZero() {
        XCTAssertEqual(HogFormat.cpu(-5.0), "0.0%")
        XCTAssertEqual(HogFormat.cpu(-0.0001), "0.0%")
        XCTAssertEqual(HogFormat.cpu(Double.nan), "0.0%")
    }

    // MARK: - HogFormat.cpu(_:scale:coreCount:)

    func testCpuPerCoreScalePassesValueThrough() {
        XCTAssertEqual(HogFormat.cpu(400.0, scale: .perCore, coreCount: 4), HogFormat.cpu(400.0))
    }

    func testCpuMachineShareScaleDividesByCoreCount() {
        XCTAssertEqual(HogFormat.cpu(400.0, scale: .machineShare, coreCount: 4), HogFormat.cpu(100.0))
        XCTAssertEqual(HogFormat.cpu(50.0, scale: .machineShare, coreCount: 2), HogFormat.cpu(25.0))
    }

    // MARK: - HogFormat.memory

    func testMemoryBelowOneGigabyteShowsIntegerMB() {
        XCTAssertEqual(HogFormat.memory(512 * 1_048_576), "512 MB")
    }

    func testMemoryAtOrAboveOneGigabyteShowsOneDecimalGB() {
        XCTAssertEqual(HogFormat.memory(1_073_741_824), "1.0 GB")
        XCTAssertEqual(HogFormat.memory(UInt64(1.5 * 1_073_741_824)), "1.5 GB")
    }

    func testMemoryBelowOneMegabyteShowsKB() {
        XCTAssertEqual(HogFormat.memory(2048), "2 KB")
        XCTAssertEqual(HogFormat.memory(100), "0 KB")
        XCTAssertEqual(HogFormat.memory(0), "0 KB")
    }

    func testMemoryNeverPrintsTheNextUnitDown() {
        // Rounding is applied before the unit is chosen, so a value that would
        // print as "1024 MB" is promoted to GB instead.
        XCTAssertEqual(HogFormat.memory(1_073_741_823), "1.0 GB")
        XCTAssertEqual(HogFormat.memory(1_073_217_536), "1.0 GB")
        XCTAssertEqual(HogFormat.memory(1_073_207_050), "1023 MB")
        XCTAssertEqual(HogFormat.memory(1_048_575), "1 MB")
        XCTAssertEqual(HogFormat.memory(1_048_064), "1 MB")
        XCTAssertEqual(HogFormat.memory(1_048_000), "1023 KB")
        XCTAssertEqual(HogFormat.rate(1_073_741_823), "1.0 GB/s")
    }

    // MARK: - HogFormat.rate

    func testRateZeroShowsZeroKBPerSecond() {
        XCTAssertEqual(HogFormat.rate(0), "0 KB/s")
        XCTAssertEqual(HogFormat.rate(-5), "0 KB/s")
        XCTAssertEqual(HogFormat.rate(Double.nan), "0 KB/s")
    }

    func testRatePositiveShowsFormattedThroughput() {
        XCTAssertEqual(HogFormat.rate(12 * 1_048_576), "12 MB/s")
    }

    // MARK: - HogFormat.duration

    func testDurationUnderOneMinuteShowsSeconds() {
        XCTAssertEqual(HogFormat.duration(45), "45 s")
        XCTAssertEqual(HogFormat.duration(0), "0 s")
        XCTAssertEqual(HogFormat.duration(-10), "0 s")
    }

    func testDurationUnderOneHourShowsMinutes() {
        XCTAssertEqual(HogFormat.duration(180), "3 min")
    }

    func testDurationAtOrAboveOneHourShowsHoursAndMinutes() {
        XCTAssertEqual(HogFormat.duration(2 * 3600 + 5 * 60), "2h 5m")
    }

    // MARK: - HogFormat.percent

    func testPercentClampsToZeroToOneRange() {
        XCTAssertEqual(HogFormat.percent(-0.2), "0%")
        XCTAssertEqual(HogFormat.percent(1.5), "100%")
        XCTAssertEqual(HogFormat.percent(0.5), "50%")
    }
}

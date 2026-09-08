import XCTest

@testable import HogHunter

final class HogFormatTests: XCTestCase {

    // MARK: - HogFormat.cpu

    func testCpuBelowRoundingFlooresToZeroPercent() {
        XCTAssertEqual(HogFormat.cpu(0.0), "0%")
        XCTAssertEqual(HogFormat.cpu(0.04), "0%")
    }

    func testCpuBelowTenShowsOneDecimal() {
        XCTAssertEqual(HogFormat.cpu(0.05), "0.1%")
        XCTAssertEqual(HogFormat.cpu(5.0), "5.0%")
        XCTAssertEqual(HogFormat.cpu(9.94), "9.9%")
    }

    func testCpuAtOrAboveTenShowsInteger() {
        XCTAssertEqual(HogFormat.cpu(10.0), "10%")
        XCTAssertEqual(HogFormat.cpu(99.6), "100%")
        XCTAssertEqual(HogFormat.cpu(250.0), "250%")
    }

    // MARK: - HogFormat.memory

    func testMemoryOneGibibyteFormatsAsOneDecimalGB() {
        XCTAssertEqual(HogFormat.memory(1_073_741_824), "1.0 GB")
    }

    func testMemoryTenMebibytesFormatsAsIntegerMB() {
        XCTAssertEqual(HogFormat.memory(10 * 1_048_576), "10 MB")
    }

    func testMemorySmallByteCountsFormatAsKB() {
        XCTAssertEqual(HogFormat.memory(2048), "2 KB")
        XCTAssertEqual(HogFormat.memory(100), "0 KB")
        XCTAssertEqual(HogFormat.memory(0), "0 KB")
    }
}

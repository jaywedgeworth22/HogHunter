import XCTest

@testable import HogHunter

/// Covers `Severity.forProcessCpu`.  The thresholds are calibrated against
/// the per-core scale (300% = 3 cores busy, 100% = 1 core busy), so the same
/// value should reach the same severity on the `machineShare` scale only
/// after being multiplied back by the core count.
final class SeverityTests: XCTestCase {

    // MARK: - Per-core scale (the default and the legacy behaviour)

    func testPerCoreBelowOneCoreIsCalm() {
        XCTAssertEqual(Severity.forProcessCpu(0, scale: .perCore, coreCount: 8), .calm)
        XCTAssertEqual(Severity.forProcessCpu(50, scale: .perCore, coreCount: 8), .calm)
        XCTAssertEqual(Severity.forProcessCpu(99.9, scale: .perCore, coreCount: 8), .calm)
    }

    func testPerCoreAtOrAboveOneCoreIsElevated() {
        XCTAssertEqual(Severity.forProcessCpu(100, scale: .perCore, coreCount: 8), .elevated)
        XCTAssertEqual(Severity.forProcessCpu(199, scale: .perCore, coreCount: 8), .elevated)
    }

    func testPerCoreAtOrAboveThreeCoresIsHot() {
        XCTAssertEqual(Severity.forProcessCpu(300, scale: .perCore, coreCount: 8), .hot)
        XCTAssertEqual(Severity.forProcessCpu(900, scale: .perCore, coreCount: 8), .hot)
    }

    // MARK: - Machine share scale

    func testMachineShareBelowOneCoreIsCalm() {
        // 1 core out of 8 is 12.5%.  Anything below that is calm.
        XCTAssertEqual(Severity.forProcessCpu(0, scale: .machineShare, coreCount: 8), .calm)
        XCTAssertEqual(Severity.forProcessCpu(12.4, scale: .machineShare, coreCount: 8), .calm)
    }

    func testMachineShareAtOneCoreIsElevated() {
        XCTAssertEqual(Severity.forProcessCpu(12.5, scale: .machineShare, coreCount: 8), .elevated)
        XCTAssertEqual(Severity.forProcessCpu(37.4, scale: .machineShare, coreCount: 8), .elevated)
    }

    func testMachineShareAtThreeCoresIsHot() {
        XCTAssertEqual(Severity.forProcessCpu(37.5, scale: .machineShare, coreCount: 8), .hot)
        XCTAssertEqual(Severity.forProcessCpu(100, scale: .machineShare, coreCount: 8), .hot)
    }

    /// The display value and the colour must agree, regardless of the scale
    /// the user picked.  This is the regression the scale-aware overload was
    /// added for: a 100% per-core process on an 8-core machine used to print
    /// as 12.5% and still colour itself elevated.
    func testDisplayValueAgreesWithSeverityOnEitherScale() {
        // Per-core 100% on an 8-core machine = 12.5% on machineShare.
        XCTAssertEqual(Severity.forProcessCpu(100, scale: .perCore, coreCount: 8),
                       Severity.forProcessCpu(12.5, scale: .machineShare, coreCount: 8))
        XCTAssertEqual(Severity.forProcessCpu(300, scale: .perCore, coreCount: 8),
                       Severity.forProcessCpu(37.5, scale: .machineShare, coreCount: 8))
    }

    /// A 4-core machine has different machineShare thresholds than an 8-core
    /// machine — 100%/4 = 25%, 300%/4 = 75% — and the severity overload must
    /// follow that.
    func testMachineShareThresholdsTrackCoreCount() {
        XCTAssertEqual(Severity.forProcessCpu(24.9, scale: .machineShare, coreCount: 4), .calm)
        XCTAssertEqual(Severity.forProcessCpu(25.0, scale: .machineShare, coreCount: 4), .elevated)
        XCTAssertEqual(Severity.forProcessCpu(74.9, scale: .machineShare, coreCount: 4), .elevated)
        XCTAssertEqual(Severity.forProcessCpu(75.0, scale: .machineShare, coreCount: 4), .hot)
    }
}

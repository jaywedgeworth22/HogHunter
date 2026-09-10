import XCTest

@testable import HogHunter

/// Covers `CpuMath` (tick-to-percent conversion, the clamp ceiling, and
/// machine-wide CPU from tick deltas) and `MemoryMath` (the Activity Monitor
/// memory formulas).  All inputs are synthetic tick counts; nothing here
/// touches a real process.
final class CpuMathTests: XCTestCase {

    /// The Apple silicon mach timebase ratio: a raw tick read as nanoseconds
    /// is 41.7x too small, so every test here goes through this ratio rather
    /// than assuming ticks are already nanoseconds.
    private let tickToNanos = 125.0 / 3.0

    // MARK: - CpuMath.percent

    func testFullTickDeltaOverElapsedYieldsOneHundredPercentForOneCore() {
        // 72,000,000 ticks * 125/3 ns/tick / 1e9 = 3.0s of CPU time over a
        // 3.0s elapsed window: one core fully busy.
        let percent = CpuMath.percent(
            currentTicks: 1_000_000 + 72_000_000,
            previousTicks: 1_000_000,
            elapsed: 3.0,
            tickToNanos: tickToNanos,
            coreCount: 1
        )
        XCTAssertEqual(percent ?? -1, 100.0, accuracy: 0.0001)
    }

    func testHalfTickDeltaYieldsFiftyPercent() {
        let percent = CpuMath.percent(
            currentTicks: 1_000_000 + 36_000_000,
            previousTicks: 1_000_000,
            elapsed: 3.0,
            tickToNanos: tickToNanos,
            coreCount: 1
        )
        XCTAssertEqual(percent ?? -1, 50.0, accuracy: 0.0001)
    }

    func testDecreasingCounterReturnsNilForFreshBaseline() {
        // A lower current tick than the previous sample means a new process
        // landed on a reused pid; the caller must start a fresh baseline
        // rather than show a wrapped delta.
        let percent = CpuMath.percent(
            currentTicks: 50,
            previousTicks: 100,
            elapsed: 3.0,
            tickToNanos: tickToNanos,
            coreCount: 1
        )
        XCTAssertNil(percent)
    }

    func testPercentClampsAtOneHundredFiftyTimesCoreCount() {
        let coreCount = 4
        // An enormous tick delta over a short elapsed time would otherwise
        // report tens of thousands of percent; it must be clamped instead of
        // shown, since the counters moved in a way that cannot be trusted.
        let percent = CpuMath.percent(
            currentTicks: 10_000_000_000,
            previousTicks: 0,
            elapsed: 1.0,
            tickToNanos: tickToNanos,
            coreCount: coreCount
        )
        XCTAssertEqual(percent ?? -1, CpuMath.ceiling(coreCount: coreCount), accuracy: 0.0001)
        XCTAssertEqual(CpuMath.ceiling(coreCount: coreCount), 600.0, accuracy: 0.0001)
    }

    /// The implementation's guard is `elapsed > 0`, so both zero and negative
    /// elapsed are treated as "nothing trustworthy to report" and return nil
    /// (not 0%, and not a crash from dividing by zero).
    func testZeroOrNegativeElapsedReturnsNil() {
        XCTAssertNil(CpuMath.percent(currentTicks: 100, previousTicks: 50, elapsed: 0, tickToNanos: tickToNanos, coreCount: 4))
        XCTAssertNil(CpuMath.percent(currentTicks: 100, previousTicks: 50, elapsed: -1, tickToNanos: tickToNanos, coreCount: 4))
    }

    // MARK: - CpuMath.machinePercent

    func testMachinePercentFromIdleAndTotalTickDeltas() {
        // Idle grew by 100 out of a 500 total-tick delta: 20% idle, 80% busy.
        let percent = CpuMath.machinePercent(idle: 150, total: 1000, previousIdle: 50, previousTotal: 500)
        XCTAssertEqual(percent ?? -1, 80.0, accuracy: 0.0001)
    }

    func testMachinePercentReturnsNilOnTotalCounterRollover() {
        // The kernel's 32-bit counters wrap; a total that dropped below the
        // previous sample means "skip this sample", not a negative delta.
        let percent = CpuMath.machinePercent(idle: 10, total: 100, previousIdle: 5, previousTotal: 1000)
        XCTAssertNil(percent)
    }

    func testMachinePercentReturnsNilOnIdleCounterRollover() {
        let percent = CpuMath.machinePercent(idle: 10, total: 1000, previousIdle: 500, previousTotal: 500)
        XCTAssertNil(percent)
    }

    // MARK: - MemoryMath.used

    func testMemoryUsedSumsAppWiredAndCompressorPages() {
        let used = MemoryMath.used(internal: 1000, purgeable: 200, wired: 300, compressor: 100, pageSize: 4096)
        // app = (1000 - 200) * 4096 = 3,276,800
        // used = app + 300*4096 + 100*4096 = 4,915,200
        XCTAssertEqual(used, 4_915_200)
    }

    func testMemoryUsedSaturatesWhenPurgeableExceedsInternal() {
        // internal < purgeable must never underflow to a huge UInt64; app
        // memory floors at 0 instead.
        let used = MemoryMath.used(internal: 100, purgeable: 500, wired: 50, compressor: 20, pageSize: 4096)
        XCTAssertEqual(used, 70 * 4096)
    }

    func testAppMemorySaturatesWhenPurgeableExceedsInternal() {
        XCTAssertEqual(MemoryMath.appMemory(internal: 100, purgeable: 500, pageSize: 4096), 0)
        XCTAssertEqual(MemoryMath.appMemory(internal: 1000, purgeable: 200, pageSize: 4096), 800 * 4096)
    }

    // MARK: - MemoryMath.cachedFiles

    func testCachedFilesSumsExternalAndPurgeablePages() {
        let cached = MemoryMath.cachedFiles(external: 400, purgeable: 150, pageSize: 4096)
        XCTAssertEqual(cached, 550 * 4096)
    }
}

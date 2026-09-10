import Foundation

/// Pure CPU arithmetic, shared by the process sampler and the machine meter.
///
/// `proc_taskinfo.pti_total_user` / `pti_total_system` and
/// `rusage_info_v4.ri_user_time` / `ri_system_time` are mach absolute-time
/// ticks, not nanoseconds.  On Apple silicon the timebase is 125/3, so a raw
/// tick count read as nanoseconds is 41.7x too small.  Everything here takes
/// the timebase ratio explicitly so the conversion cannot be forgotten.
enum CpuMath {
    /// The most a single process may be reported as using: 150% of the machine.
    /// A larger value means the counters moved in a way we cannot explain, so
    /// it is clamped rather than shown.
    static func ceiling(coreCount: Int) -> Double {
        100 * Double(max(1, coreCount)) * 1.5
    }

    /// Per-process CPU on Activity Monitor's scale, where 100% is one core
    /// fully busy.
    ///
    /// Returns `nil` when there is nothing trustworthy to report: a
    /// non-positive elapsed time, or a counter that decreased.  A decreasing
    /// counter means the pid was reused by a different process, so the caller
    /// should start a fresh baseline instead of showing a wrapped delta.
    static func percent(
        currentTicks: UInt64,
        previousTicks: UInt64,
        elapsed: TimeInterval,
        tickToNanos: Double,
        coreCount: Int
    ) -> Double? {
        guard elapsed > 0, elapsed.isFinite, tickToNanos > 0 else { return nil }
        guard currentTicks >= previousTicks else { return nil }
        let deltaSeconds = Double(currentTicks - previousTicks) * tickToNanos / 1_000_000_000
        let percent = deltaSeconds / elapsed * 100
        guard percent.isFinite else { return nil }
        return min(max(0, percent), ceiling(coreCount: coreCount))
    }

    /// A per-second rate from two monotonic byte or event counters.  Returns 0
    /// when the counter decreased, which again means a reused pid.
    static func rate(current: UInt64, previous: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, elapsed.isFinite, current >= previous else { return 0 }
        return Double(current - previous) / elapsed
    }

    /// Machine CPU from `host_statistics(HOST_CPU_LOAD_INFO)` tick totals.
    /// The kernel's counters are 32 bit and do roll over; a decreasing total or
    /// idle count yields `nil`, meaning "skip this sample".
    static func machinePercent(
        idle: UInt64,
        total: UInt64,
        previousIdle: UInt64,
        previousTotal: UInt64
    ) -> Double? {
        guard total >= previousTotal, idle >= previousIdle else { return nil }
        let totalDelta = Double(total - previousTotal)
        guard totalDelta > 0 else { return nil }
        let idleDelta = Double(idle - previousIdle)
        return min(max(0, (1 - idleDelta / totalDelta) * 100), 100)
    }

    /// The machine's timebase ratio, read once.
    static let tickToNanos: Double = {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom != 0 else { return 1 }
        return Double(timebase.numer) / Double(timebase.denom)
    }()

    /// A monotonic clock in seconds, on the same base as `ri_proc_start_abstime`.
    static func now() -> TimeInterval {
        Double(mach_absolute_time()) * tickToNanos / 1_000_000_000
    }
}

/// Pure memory arithmetic over `vm_statistics64` page counts.
enum MemoryMath {
    /// Activity Monitor's "Memory Used": app memory plus wired plus compressed.
    /// App memory is internal pages that are not purgeable.
    static func used(
        `internal` internalPages: UInt64,
        purgeable purgeablePages: UInt64,
        wired wiredPages: UInt64,
        compressor compressorPages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        let app = appMemory(internal: internalPages, purgeable: purgeablePages, pageSize: pageSize)
        return app &+ wiredPages &* pageSize &+ compressorPages &* pageSize
    }

    static func appMemory(
        `internal` internalPages: UInt64,
        purgeable purgeablePages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        let net = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return net &* pageSize
    }

    /// Activity Monitor's "Cached Files": external pages plus purgeable pages.
    static func cachedFiles(
        external externalPages: UInt64,
        purgeable purgeablePages: UInt64,
        pageSize: UInt64
    ) -> UInt64 {
        (externalPages &+ purgeablePages) &* pageSize
    }
}

import AppKit
import Darwin
import Foundation

/// Live process + machine snapshot.  CPU percent matches Activity Monitor:
/// 100% is one core fully busy.  `proc_taskinfo` CPU counters are mach
/// absolute-time ticks — convert with `mach_timebase_info` before /1e9.
final class Sampler {
    private struct CpuSample {
        /// Sum of `pti_total_user` + `pti_total_system` — mach absolute-time ticks, not ns.
        var userSysTicks: UInt64
        var at: TimeInterval
    }

    private var previous: [Int32: CpuSample] = [:]
    private var lastMachineTicks: (idle: UInt64, total: UInt64)?
    /// Cached once; converts mach absolute-time ticks to nanoseconds.
    private let tickToNanos: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    func snapshot(limit: Int = 40) -> (pulse: MachinePulse, rows: [LiveProcess]) {
        let now = ProcessInfo.processInfo.systemUptime
        let pids = listPids()
        var live: [LiveProcess] = []
        live.reserveCapacity(pids.count)

        for pid in pids {
            guard pid > 0 else { continue }
            guard var info = taskInfo(pid) else { continue }
            let cpuTicks = info.pti_total_user &+ info.pti_total_system
            var cpuPercent = 0.0
            if let prior = previous[pid] {
                let elapsed = now - prior.at
                if elapsed > 0.05 {
                    let deltaTicks = Double(cpuTicks &- prior.userSysTicks)
                    let deltaSeconds = deltaTicks * tickToNanos / 1_000_000_000
                    cpuPercent = max(0, deltaSeconds / elapsed * 100)
                }
            }
            previous[pid] = CpuSample(userSysTicks: cpuTicks, at: now)

            let path = processPath(pid)
            let running = NSRunningApplication(processIdentifier: pid)
            let name = running?.localizedName
                ?? (path as NSString?)?.lastPathComponent
                ?? processName(pid)
            live.append(
                LiveProcess(
                    pid: pid,
                    name: name,
                    path: path,
                    bundleId: running?.bundleIdentifier,
                    cpuPercent: cpuPercent,
                    memoryBytes: info.pti_resident_size,
                    icon: running?.icon
                )
            )
        }

        let seen = Set(live.map(\.pid))
        previous = previous.filter { seen.contains($0.key) }

        live.sort { $0.cpuPercent == $1.cpuPercent ? $0.memoryBytes > $1.memoryBytes : $0.cpuPercent > $1.cpuPercent }
        let pulse = MachinePulse(
            cpuPercent: machineCpuPercent(),
            usedMemoryBytes: usedMemory(),
            totalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processCount: live.count
        )
        return (pulse, Array(live.prefix(limit)))
    }

    struct LiveProcess {
        var pid: Int32
        var name: String
        var path: String
        var bundleId: String?
        var cpuPercent: Double
        var memoryBytes: UInt64
        var icon: NSImage?
    }

    private func listPids() -> [pid_t] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [] }
        let count = Int(bytesNeeded) / MemoryLayout<pid_t>.stride
        var pids = Array(repeating: pid_t(0), count: count)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(bytesNeeded))
        guard written > 0 else { return [] }
        let n = Int(written) / MemoryLayout<pid_t>.stride
        return Array(pids.prefix(n)).filter { $0 > 0 }
    }

    private func taskInfo(_ pid: pid_t) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
        guard got == size else { return nil }
        return info
    }

    private func processPath(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard n > 0 else { return "" }
        return String(cString: buffer)
    }

    private func processName(_ pid: pid_t) -> String {
        var name = [CChar](repeating: 0, count: 64)
        let n = proc_name(pid, &name, UInt32(name.count))
        guard n > 0 else { return "pid \(pid)" }
        return String(cString: name)
    }

    private func machineCpuPercent() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info_data_t()
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let idle = UInt64(info.cpu_ticks.2) // CPU_STATE_IDLE
        let total = UInt64(info.cpu_ticks.0) &+ UInt64(info.cpu_ticks.1) &+ UInt64(info.cpu_ticks.2) &+ UInt64(info.cpu_ticks.3)
        defer { lastMachineTicks = (idle, total) }
        guard let prior = lastMachineTicks else { return 0 }
        let idleDelta = Double(idle &- prior.idle)
        let totalDelta = Double(total &- prior.total)
        guard totalDelta > 0 else { return 0 }
        return max(0, min(100, (1 - idleDelta / totalDelta) * 100))
    }

    private func usedMemory() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let page = UInt64(vm_kernel_page_size)
        let used = UInt64(stats.active_count) &+ UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count)
        return used &* page
    }
}

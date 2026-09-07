import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class HogStore: ObservableObject {
    @Published var pulse = MachinePulse(cpuPercent: 0, usedMemoryBytes: 0, totalMemoryBytes: 0, processCount: 0)
    @Published var rows: [HogRow] = []
    @Published var window: TimeWindow = .now
    @Published var sort: HogSort = .cpu
    @Published var grouping: HogGrouping = .apps
    @Published var launchesAtLogin = false
    @Published var historyCoverage: TimeInterval = 0
    @Published var lastError: String?

    private let sampler = Sampler()
    private let history = HistoryStore()
    private var live: [Sampler.LiveProcess] = []
    private var timer: Timer?
    private var sampleCount = 0

    init() {
        Task { @MainActor in
            self.start()
        }
    }

    func start() {
        guard timer == nil else { return }
        refreshLoginItem()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() {
        let snap = sampler.snapshot(limit: 80)
        pulse = snap.pulse
        live = snap.rows
        sampleCount += 1
        if sampleCount % 5 == 0 {
            history.record(snap.rows)
            if sampleCount % 60 == 0 { history.prune() }
        }
        historyCoverage = history.oldestSampleAge() ?? 0
        rebuildRows()
    }

    func rebuildRows() {
        switch window {
        case .now:
            rows = rankLive(live)
        case .hour, .day:
            let lookback = window.lookback ?? 3600
            let agg = history.aggregates(lookback: lookback, groupByApp: grouping == .apps)
            rows = agg.map { item in
                HogRow(
                    id: item.key,
                    pid: 0,
                    pids: [],
                    name: displayName(bundleId: item.bundleId, fallback: item.name),
                    detail: historyDetail(item),
                    cpuPercent: item.avgCpu,
                    memoryBytes: UInt64(item.avgMem),
                    icon: icon(forBundle: item.bundleId),
                    isApp: grouping == .apps,
                    canKill: false
                )
            }.sorted(by: sortFn)
        }
    }

    func quit(_ row: HogRow, force: Bool) {
        lastError = nil
        let pids = row.pids.isEmpty ? (row.pid > 0 ? [row.pid] : []) : row.pids
        guard !pids.isEmpty else {
            lastError = "That hog is only in history.  Switch to Now to quit a live process."
            return
        }
        let signal = force ? SIGKILL : SIGTERM
        var failed: [Int32] = []
        for pid in pids {
            if pid == getpid() { continue }
            if kill(pid, signal) != 0 { failed.append(pid) }
        }
        if !failed.isEmpty {
            lastError = "Could not quit pid \(failed.map(String.init).joined(separator: ", "))."
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.tick()
        }
    }

    func toggleLoginItem() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLoginItem()
        } catch {
            lastError = error.localizedDescription
        }
    }

    var menuBarLabel: String {
        let top = live.first?.cpuPercent ?? 0
        if pulse.cpuPercent >= 1 {
            return HogFormat.cpu(pulse.cpuPercent)
        }
        return HogFormat.cpu(top)
    }

    var coverageNote: String {
        if window == .now { return "Live snapshot.  100% CPU is one core fully busy." }
        if historyCoverage < 30 {
            return "History starts when Hog Hunter is open.  Turn on Launch at Login for a full day."
        }
        let minutes = Int(historyCoverage / 60)
        if minutes < 60 {
            return "Covering the last \(minutes) min Hog Hunter has been open."
        }
        let hours = minutes / 60
        return "Covering the last \(hours)h \(minutes % 60)m Hog Hunter has been open."
    }

    private func rankLive(_ processes: [Sampler.LiveProcess]) -> [HogRow] {
        let filtered = processes.filter { $0.name != "kernel_task" }
        if grouping == .processes {
            return filtered.prefix(25).map { proc in
                HogRow(
                    id: "p-\(proc.pid)",
                    pid: proc.pid,
                    pids: [proc.pid],
                    name: proc.name,
                    detail: "pid \(proc.pid)",
                    cpuPercent: proc.cpuPercent,
                    memoryBytes: proc.memoryBytes,
                    icon: proc.icon,
                    isApp: false,
                    canKill: proc.pid != getpid() && proc.pid > 1
                )
            }.sorted(by: sortFn)
        }

        var groups: [String: [Sampler.LiveProcess]] = [:]
        for proc in filtered {
            let key = proc.bundleId ?? proc.name
            groups[key, default: []].append(proc)
        }
        return groups.map { key, members in
            let cpu = members.reduce(0.0) { $0 + $1.cpuPercent }
            let mem = members.reduce(UInt64(0)) { $0 + $1.memoryBytes }
            let primary = members.max { $0.memoryBytes < $1.memoryBytes } ?? members[0]
            let extra = members.count > 1 ? " · \(members.count) processes" : ""
            return HogRow(
                id: "a-\(key)",
                pid: primary.pid,
                pids: members.map(\.pid),
                name: primary.name,
                detail: (primary.bundleId ?? "pid \(primary.pid)") + extra,
                cpuPercent: cpu,
                memoryBytes: mem,
                icon: primary.icon,
                isApp: true,
                canKill: members.contains { $0.pid != getpid() && $0.pid > 1 }
            )
        }
        .sorted(by: sortFn)
        .prefix(20)
        .map { $0 }
    }

    private func sortFn(_ a: HogRow, _ b: HogRow) -> Bool {
        switch sort {
        case .cpu:
            if a.cpuPercent == b.cpuPercent { return a.memoryBytes > b.memoryBytes }
            return a.cpuPercent > b.cpuPercent
        case .memory:
            if a.memoryBytes == b.memoryBytes { return a.cpuPercent > b.cpuPercent }
            return a.memoryBytes > b.memoryBytes
        }
    }

    private func historyDetail(_ item: HistoryStore.Aggregate) -> String {
        let mem = HogFormat.memory(item.maxMem)
        return "avg CPU · peak \(mem)"
    }

    private func displayName(bundleId: String?, fallback: String) -> String {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return fallback
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func icon(forBundle bundleId: String?) -> NSImage? {
        guard let bundleId, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func refreshLoginItem() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }
}

import AppKit
import Combine
import Darwin
import Foundation
import ServiceManagement

/// Everything the panel binds to.
///
/// The store lives on the main actor, but nothing expensive happens there: a
/// serial utility queue owns the sampler and the history database, and results
/// hop back to the main actor to be turned into rows.  A tick that fires while
/// the previous one is still running is skipped rather than queued, so a busy
/// machine cannot make Hog Hunter the hog.
@MainActor
final class HogStore: ObservableObject {
    // MARK: - Published state

    @Published private(set) var pulse = MachinePulse.empty
    @Published private(set) var rows: [HogRow] = []
    @Published private(set) var hasBaseline = false
    @Published private(set) var isStale = false
    @Published private(set) var launchesAtLogin = false
    @Published var lastError: String?

    /// Set by the panel.  Metadata resolution beyond the menu bar's top hog and
    /// all history aggregation are gated on this.
    @Published var panelVisible = false {
        didSet {
            guard panelVisible, panelVisible != oldValue else { return }
            refreshHistory()
        }
    }

    // MARK: - Persisted choices

    @Published var window: TimeWindow = .now { didSet { persist(); choiceChanged() } }
    @Published var grouping: HogGrouping = .apps { didSet { persist(); choiceChanged() } }
    @Published var sort: HogSort = .cpu { didSet { persist(); choiceChanged() } }
    @Published var cpuScale: CpuScale = .perCore { didSet { persist() } }
    @Published var menuBarLabelMode: MenuBarLabelMode = .machinePercent { didSet { persist() } }
    @Published var refreshInterval: TimeInterval = 3 { didSet { persist(); restartTimer() } }

    /// UserDefaults keys, shared with any `@AppStorage` view that edits them.
    enum Key {
        static let window = "window"
        static let grouping = "grouping"
        static let sort = "sort"
        static let cpuScale = "cpuScale"
        static let menuBarLabelMode = "menuBarLabelMode"
        static let refreshInterval = "refreshInterval"
    }

    // MARK: - Machinery

    private let queue = DispatchQueue(label: "hoghunter.sampling", qos: .utility)
    private let sampler = Sampler()
    private let history: HistoryStore
    private let resolver = MetadataResolver()
    private let defaults: UserDefaults

    private var timer: Timer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var isSampling = false
    private var started = false
    private var tickIndex = 0
    private var loadingSettings = false

    private var samples: [ProcessKey: ProcessSample] = [:]
    private var liveRows: [HogRow] = []
    private var historyRows: [HogRow] = []
    private var coverage = HistoryStore.Coverage(tickCount: 0, sampledSeconds: 0, firstTimestamp: nil)

    /// History is written every fifth tick, so one history tick covers five
    /// refresh intervals.
    private static let recordEvery = 5
    private static let rowLimit = 25

    init(historyURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.history = HistoryStore(url: historyURL ?? HistoryStore.defaultURL)
        loadSettings()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        start()
    }

    deinit {
        timer?.invalidate()
        pressureSource?.cancel()
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshLoginItem()
        tick()
        restartTimer()
        watchMemoryPressure()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
    }

    private func restartTimer() {
        guard started else { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStaleness()
                self?.tick()
            }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        source.resume()
        pressureSource = source
    }

    // MARK: - Sampling

    func tick() {
        guard !isSampling else { return }
        isSampling = true
        let sampler = self.sampler
        queue.async {
            let snapshot = sampler.snapshot()
            DispatchQueue.main.async { [weak self] in
                self?.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: Snapshot) {
        isSampling = false
        tickIndex += 1
        pulse = snapshot.pulse
        hasBaseline = snapshot.hasBaseline
        isStale = false

        samples = Dictionary(uniqueKeysWithValues: snapshot.processes.map { ($0.key, $0) })
        resolver.refreshRunningApps()
        let groups = Grouping.groups(
            snapshot.processes,
            isRegularApp: { [resolver] pid in resolver.isRegularApp(pid) },
            bundleId: { [resolver] pid in resolver.bundleId(pid) }
        )

        var groupKeyByProcess: [ProcessKey: String] = [:]
        for group in groups {
            for member in group.members { groupKeyByProcess[member.key] = group.key }
        }

        liveRows = buildLiveRows(snapshot.processes, groups: groups)
        if window == .now { rows = liveRows }

        if tickIndex % Self.recordEvery == 0 {
            record(snapshot.processes, groupKeys: groupKeyByProcess, coreCount: snapshot.pulse.coreCount)
        }
        if tickIndex % 20 == 0 {
            resolver.pruneIfNeeded(live: Set(samples.keys))
        }
        if window != .now { refreshHistory() }
    }

    private func record(_ processes: [ProcessSample], groupKeys: [ProcessKey: String], coreCount: Int) {
        var bundles: [ProcessKey: String] = [:]
        for process in processes {
            if let bundle = resolver.bundleId(process.key.pid) { bundles[process.key] = bundle }
        }
        let history = self.history
        queue.async {
            history.record(
                samples: processes,
                groupKey: { groupKeys[$0.key] ?? "proc:\($0.key.pid)-\($0.key.startTime)" },
                bundleId: { bundles[$0.key] },
                coreCount: coreCount
            )
            history.prune()
        }
    }

    // MARK: - Live rows

    private func buildLiveRows(_ processes: [ProcessSample], groups: [Grouping.Group]) -> [HogRow] {
        if grouping == .processes {
            // Sorted before truncation, so the top 25 really are the top 25.
            let ranked = processes.sorted(by: processOrder).prefix(Self.rowLimit)
            let metadata = resolver.resolve(ranked.map(\.key), samples: samples)
            return ranked.map { process in
                let reason = ProcessControl.blockReason(for: process)
                return HogRow(
                    id: "p-\(process.key.pid)-\(process.key.startTime)",
                    keys: [process.key],
                    name: metadata[process.key]?.displayName ?? process.name,
                    detail: "pid \(process.key.pid) · \(process.threadCount) threads",
                    cpuPercent: process.cpuPercent,
                    memoryBytes: process.footprintBytes,
                    peakMemoryBytes: nil,
                    presence: nil,
                    icon: metadata[process.key]?.icon,
                    path: process.path.isEmpty ? nil : process.path,
                    isApp: metadata[process.key]?.activationPolicy == .regular,
                    isGroup: false,
                    canQuit: reason == nil,
                    quitBlockReason: reason
                )
            }
        }

        let ranked = groups.sorted(by: groupOrder).prefix(Self.rowLimit)
        let anchors = ranked.map { group -> ProcessKey in
            if let owner = group.ownerPid,
               let sample = group.members.first(where: { $0.key.pid == owner }) {
                return sample.key
            }
            return group.members.max(by: { $0.footprintBytes < $1.footprintBytes })?.key ?? group.members[0].key
        }
        let metadata = resolver.resolve(anchors, samples: samples)

        return zip(ranked, anchors).map { group, anchor in
            let blocks = group.members.map { ProcessControl.blockReason(for: $0) }
            let canQuit = blocks.contains(where: { $0 == nil })
            return HogRow(
                id: "a-\(group.key)",
                keys: group.members.map(\.key),
                name: metadata[anchor]?.displayName ?? group.name,
                detail: groupDetail(group),
                cpuPercent: group.cpuPercent,
                memoryBytes: group.memoryBytes,
                peakMemoryBytes: nil,
                presence: nil,
                icon: metadata[anchor]?.icon,
                path: group.path,
                isApp: group.isApp,
                isGroup: group.members.count > 1,
                canQuit: canQuit,
                quitBlockReason: canQuit ? nil : blocks.compactMap { $0 }.first
            )
        }
    }

    private func groupDetail(_ group: Grouping.Group) -> String {
        let count = group.members.count
        let suffix = count > 1 ? " · \(count) processes" : ""
        if let bundle = group.bundleId, !bundle.isEmpty { return bundle + suffix }
        if let owner = group.ownerPid { return "pid \(owner)" + suffix }
        return "pid \(group.members[0].key.pid)" + suffix
    }

    private func processOrder(_ a: ProcessSample, _ b: ProcessSample) -> Bool {
        switch sort {
        case .cpu:
            if a.cpuPercent == b.cpuPercent { return a.footprintBytes > b.footprintBytes }
            return a.cpuPercent > b.cpuPercent
        case .memory:
            if a.footprintBytes == b.footprintBytes { return a.cpuPercent > b.cpuPercent }
            return a.footprintBytes > b.footprintBytes
        }
    }

    private func groupOrder(_ a: Grouping.Group, _ b: Grouping.Group) -> Bool {
        switch sort {
        case .cpu:
            if a.cpuPercent == b.cpuPercent { return a.memoryBytes > b.memoryBytes }
            return a.cpuPercent > b.cpuPercent
        case .memory:
            if a.memoryBytes == b.memoryBytes { return a.cpuPercent > b.cpuPercent }
            return a.memoryBytes > b.memoryBytes
        }
    }

    // MARK: - History rows

    private func choiceChanged() {
        if window == .now {
            rows = liveRows
        } else {
            rows = historyRows
            refreshHistory()
        }
    }

    private func refreshHistory() {
        guard let lookback = window.lookback, panelVisible else { return }
        let history = self.history
        let groupByApp = grouping == .apps
        let sort = self.sort
        let secondsPerTick = refreshInterval * Double(Self.recordEvery)
        queue.async {
            let aggregates = history.aggregates(lookback: lookback, groupByApp: groupByApp, sort: sort)
            let coverage = history.coverage(lookback: lookback, secondsPerTick: secondsPerTick)
            let error = history.lastError
            DispatchQueue.main.async { [weak self] in
                self?.applyHistory(aggregates, coverage: coverage, error: error)
            }
        }
    }

    private func applyHistory(
        _ aggregates: [HistoryStore.Aggregate],
        coverage: HistoryStore.Coverage,
        error: String?
    ) {
        self.coverage = coverage
        if let error { lastError = error }
        historyRows = aggregates.prefix(Self.rowLimit).map { item in
            HogRow(
                id: "h-\(item.key)",
                keys: [],
                name: resolver.displayName(bundleId: item.bundleId, fallback: item.name),
                detail: historyDetail(item),
                cpuPercent: item.avgCpu,
                memoryBytes: UInt64(max(0, item.avgMemoryBytes)),
                peakMemoryBytes: item.peakMemoryBytes,
                presence: item.presence,
                icon: resolver.icon(bundleId: item.bundleId, path: nil),
                path: nil,
                isApp: item.bundleId != nil,
                isGroup: false,
                canQuit: false,
                quitBlockReason: "only in history"
            )
        }
        if window != .now { rows = historyRows }
    }

    private func historyDetail(_ item: HistoryStore.Aggregate) -> String {
        "avg CPU · peak \(HogFormat.memory(item.peakMemoryBytes)) · seen \(HogFormat.percent(item.presence))"
    }

    // MARK: - Captions

    var cpuCaption: String {
        "\(HogFormat.percent(pulse.cpuPercent / 100)) of all \(pulse.coreCount) cores"
    }

    var memoryCaption: String {
        var parts = ["\(gigabytes(pulse.memoryUsedBytes)) of \(gigabytes(pulse.totalMemoryBytes)) GB"]
        if pulse.swapUsedBytes > 0 {
            parts.append("\(HogFormat.memory(pulse.swapUsedBytes)) swapped")
        }
        if pulse.pressure != .unknown {
            parts.append("pressure \(pulse.pressure.label)")
        }
        return parts.joined(separator: " · ")
    }

    var swapRateCaption: String? {
        let inRate = pulse.swapInBytesPerSec
        let outRate = pulse.swapOutBytesPerSec
        guard inRate >= 1024 || outRate >= 1024 else { return nil }
        if outRate > inRate { return "swapping out \(HogFormat.rate(outRate))" }
        return "swapping in \(HogFormat.rate(inRate))"
    }

    /// Who the machine's CPU belongs to, and how much of it we cannot see.
    var attributionCaption: String {
        let visible = HogFormat.percent(pulse.visibleCpuPercent / 100)
        let rest = HogFormat.percent(pulse.invisibleCpuPercent / 100)
        return "\(visible) attributed to \(pulse.readableProcessCount) visible processes · "
            + "\(rest) other users, root and kernel (\(pulse.unreadableProcessCount) processes not readable)"
    }

    var scaleLegend: String {
        switch cpuScale {
        case .perCore: return "Rows: % of one core.  Header: % of all cores."
        case .machineShare: return "Rows and header: % of all cores."
        }
    }

    var coverageNote: String {
        if window == .now { return "Live snapshot.  100% CPU is one core fully busy." }
        guard coverage.tickCount > 0 else {
            return "History starts when Hog Hunter is open.  Turn on Launch at Login for a full day."
        }
        let windowLabel = window == .day ? "24 h" : "hour"
        return "Sampled \(HogFormat.duration(coverage.sampledSeconds)) of the last \(windowLabel)."
    }

    var menuBarLabel: String {
        switch menuBarLabelMode {
        case .machinePercent:
            return HogFormat.percent(pulse.cpuPercent / 100)
        case .topHogName:
            guard let top = liveRows.max(by: { $0.cpuPercent < $1.cpuPercent }), top.cpuPercent >= 1 else {
                return HogFormat.percent(pulse.cpuPercent / 100)
            }
            return "\(top.name) \(HogFormat.cpu(top.cpuPercent, scale: cpuScale, coreCount: pulse.coreCount))"
        }
    }

    var menuBarHelp: String {
        switch menuBarLabelMode {
        case .machinePercent:
            return "CPU across all \(pulse.coreCount) cores."
        case .topHogName:
            switch cpuScale {
            case .perCore: return "Busiest app, as % of one core."
            case .machineShare: return "Busiest app, as % of all \(pulse.coreCount) cores."
            }
        }
    }

    private func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        if value == value.rounded() { return String(format: "%.0f", value) }
        return String(format: "%.1f", value)
    }

    // MARK: - Actions

    func quit(_ row: HogRow, force: Bool) {
        lastError = nil
        let outcome = ProcessControl.quit(row, force: force)
        lastError = outcome.message
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
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

    private func refreshLoginItem() {
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Settings

    private func loadSettings() {
        loadingSettings = true
        defer { loadingSettings = false }
        if let raw = defaults.string(forKey: Key.window), let value = TimeWindow(rawValue: raw) { window = value }
        if let raw = defaults.string(forKey: Key.grouping), let value = HogGrouping(rawValue: raw) { grouping = value }
        if let raw = defaults.string(forKey: Key.sort), let value = HogSort(rawValue: raw) { sort = value }
        if let raw = defaults.string(forKey: Key.cpuScale), let value = CpuScale(rawValue: raw) { cpuScale = value }
        if let raw = defaults.string(forKey: Key.menuBarLabelMode), let value = MenuBarLabelMode(rawValue: raw) {
            menuBarLabelMode = value
        }
        let interval = defaults.double(forKey: Key.refreshInterval)
        if interval >= 1 { refreshInterval = interval }
    }

    private func persist() {
        guard !loadingSettings else { return }
        defaults.set(window.rawValue, forKey: Key.window)
        defaults.set(grouping.rawValue, forKey: Key.grouping)
        defaults.set(sort.rawValue, forKey: Key.sort)
        defaults.set(cpuScale.rawValue, forKey: Key.cpuScale)
        defaults.set(menuBarLabelMode.rawValue, forKey: Key.menuBarLabelMode)
        defaults.set(refreshInterval, forKey: Key.refreshInterval)
    }

    /// Picks up changes a Settings view made through `@AppStorage` on the same
    /// keys.  Values are only assigned when they actually differ, so this
    /// cannot loop against `persist()`.
    @objc private func defaultsChanged() {
        Task { @MainActor [weak self] in
            guard let self, !self.loadingSettings else { return }
            self.loadingSettings = true
            defer { self.loadingSettings = false }
            if let raw = self.defaults.string(forKey: Key.window),
               let value = TimeWindow(rawValue: raw), value != self.window {
                self.window = value
                self.choiceChanged()
            }
            if let raw = self.defaults.string(forKey: Key.grouping),
               let value = HogGrouping(rawValue: raw), value != self.grouping {
                self.grouping = value
                self.choiceChanged()
            }
            if let raw = self.defaults.string(forKey: Key.sort),
               let value = HogSort(rawValue: raw), value != self.sort {
                self.sort = value
                self.choiceChanged()
            }
            if let raw = self.defaults.string(forKey: Key.cpuScale),
               let value = CpuScale(rawValue: raw), value != self.cpuScale {
                self.cpuScale = value
            }
            if let raw = self.defaults.string(forKey: Key.menuBarLabelMode),
               let value = MenuBarLabelMode(rawValue: raw), value != self.menuBarLabelMode {
                self.menuBarLabelMode = value
            }
            let interval = self.defaults.double(forKey: Key.refreshInterval)
            if interval >= 1, interval != self.refreshInterval {
                self.refreshInterval = interval
            }
        }
    }

    // MARK: - Staleness

    /// Called by the panel's timer-free redraws; cheap enough to run often.
    func refreshStaleness(now: Date = Date()) {
        isStale = pulse.sampledAt != .distantPast
            && now.timeIntervalSince(pulse.sampledAt) > 3 * refreshInterval
    }
}

import Darwin
import Foundation

/// Pure grouping of samples into "apps".  No AppKit here: the caller passes in
/// what it knows about which pids are regular applications and what their
/// bundle identifiers are, which keeps this testable and keeps LaunchServices
/// out of the sampling path.
enum Grouping {
    struct Group {
        /// Stable across ticks: a bundle id or an owner pid, never a bare name.
        var key: String
        var ownerPid: pid_t?
        var bundleId: String?
        var name: String
        var path: String?
        var members: [ProcessSample]
        var cpuPercent: Double
        var memoryBytes: UInt64
        /// True when the group is owned by a regular (Dock-visible) app.
        var isApp: Bool
    }

    /// How far a ppid walk may go before giving up.  Real trees are shallow;
    /// this only exists so a corrupted or racing table cannot spin.
    private static let maxDepth = 32

    static func groups(
        _ samples: [ProcessSample],
        isRegularApp: (pid_t) -> Bool,
        bundleId: (pid_t) -> String?
    ) -> [Group] {
        var byPid: [pid_t: ProcessSample] = [:]
        byPid.reserveCapacity(samples.count)
        for sample in samples { byPid[sample.key.pid] = sample }

        // An array plus an index, rather than a dictionary of structs: merging
        // through `built[key]` would make `members` non-uniquely referenced and
        // deep-copy the array on every member added.
        var groups: [Group] = []
        var index: [String: Int] = [:]

        for sample in samples {
            let owner = owningApp(of: sample, byPid: byPid, isRegularApp: isRegularApp)
            let groupKey: String
            let isApp: Bool
            if let owner {
                groupKey = "app:" + (bundleId(owner) ?? "pid-\(owner)")
                isApp = true
            } else if let bundle = bundleId(sample.key.pid), !bundle.isEmpty {
                groupKey = "bundle:" + bundle
                isApp = false
            } else if !sample.path.isEmpty {
                groupKey = "path:" + sample.path
                isApp = false
            } else {
                // No bundle and no path: keep it to itself.  Two unrelated
                // processes must never merge on a bare name.
                groupKey = "proc:\(sample.key.pid)-\(sample.key.startTime)"
                isApp = false
            }

            if let position = index[groupKey] {
                groups[position].members.append(sample)
                groups[position].cpuPercent += sample.cpuPercent
                groups[position].memoryBytes = groups[position].memoryBytes &+ sample.footprintBytes
            } else {
                let ownerSample = owner.flatMap { byPid[$0] }
                let primary = ownerSample ?? sample
                index[groupKey] = groups.count
                groups.append(Group(
                    key: groupKey,
                    ownerPid: owner,
                    bundleId: owner.flatMap(bundleId) ?? bundleId(sample.key.pid),
                    name: primary.name,
                    path: primary.path.isEmpty ? nil : primary.path,
                    members: [sample],
                    cpuPercent: sample.cpuPercent,
                    memoryBytes: sample.footprintBytes,
                    isApp: isApp
                ))
            }
        }

        return groups
    }

    /// Nearest ancestor (or the process itself) that is a regular app.  The
    /// depth cap is what bounds the walk, so a ppid cycle or a self-parent
    /// simply runs out of depth and yields no owner.
    private static func owningApp(
        of sample: ProcessSample,
        byPid: [pid_t: ProcessSample],
        isRegularApp: (pid_t) -> Bool
    ) -> pid_t? {
        var pid = sample.key.pid
        var depth = 0
        while pid > 1, depth < maxDepth {
            if isRegularApp(pid) { return pid }
            guard let parent = byPid[pid]?.ppid, parent > 1 else { return nil }
            pid = parent
            depth += 1
        }
        return nil
    }
}

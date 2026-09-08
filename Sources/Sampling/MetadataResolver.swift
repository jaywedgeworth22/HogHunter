import AppKit
import Foundation

/// Turns process keys into names, bundle identifiers and icons.
///
/// Everything here touches AppKit, so it lives on the main actor and is only
/// asked about rows that are about to be drawn.  Icons and application URLs are
/// cached by bundle id, which is where the expensive LaunchServices lookups
/// happen; the per-key cache keeps a redrawn row from repeating the work.
@MainActor
final class MetadataResolver {
    struct Metadata {
        var displayName: String
        var bundleId: String?
        var icon: NSImage?
        var activationPolicy: NSApplication.ActivationPolicy?
        var isRunningApplication: Bool
    }

    /// What `NSWorkspace.runningApplications` already knows, refreshed once per
    /// tick.  This is in-process state, not a LaunchServices query, so it is
    /// cheap enough to read for every pid.
    struct AppInfo {
        var bundleId: String?
        var localizedName: String?
        var activationPolicy: NSApplication.ActivationPolicy
        var bundleURL: URL?
    }

    private(set) var runningApps: [pid_t: AppInfo] = [:]
    private var cache: [ProcessKey: Metadata] = [:]
    private var iconByBundle: [String: NSImage?] = [:]
    private var iconByPath: [String: NSImage?] = [:]
    private var urlByBundle: [String: URL?] = [:]
    private var ticksSincePrune = 0

    /// Refreshes the running-application table and returns it.
    @discardableResult
    func refreshRunningApps() -> [pid_t: AppInfo] {
        var table: [pid_t: AppInfo] = [:]
        for app in NSWorkspace.shared.runningApplications {
            table[app.processIdentifier] = AppInfo(
                bundleId: app.bundleIdentifier,
                localizedName: app.localizedName,
                activationPolicy: app.activationPolicy,
                bundleURL: app.bundleURL
            )
        }
        runningApps = table
        return table
    }

    func isRegularApp(_ pid: pid_t) -> Bool {
        runningApps[pid]?.activationPolicy == .regular
    }

    func bundleId(_ pid: pid_t) -> String? {
        runningApps[pid]?.bundleId
    }

    /// Resolves only the keys asked for.  Anything already cached is returned
    /// without touching AppKit again.
    func resolve(_ keys: [ProcessKey], samples: [ProcessKey: ProcessSample]) -> [ProcessKey: Metadata] {
        var out: [ProcessKey: Metadata] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            if let cached = cache[key] {
                out[key] = cached
                continue
            }
            let sample = samples[key]
            let app = runningApps[key.pid]
            let bundle = app?.bundleId
            let name = app?.localizedName ?? sample?.name ?? "pid \(key.pid)"
            let metadata = Metadata(
                displayName: name,
                bundleId: bundle,
                icon: icon(bundleId: bundle, bundleURL: app?.bundleURL, path: sample?.path),
                activationPolicy: app?.activationPolicy,
                isRunningApplication: app != nil
            )
            cache[key] = metadata
            out[key] = metadata
        }
        return out
    }

    /// The icon for a bundle id, an already-known bundle URL, or an executable
    /// path, in that order of preference.
    func icon(bundleId: String?, bundleURL: URL? = nil, path: String?) -> NSImage? {
        if let bundleId, !bundleId.isEmpty {
            if let cached = iconByBundle[bundleId] { return cached }
            let url = bundleURL ?? applicationURL(bundleId: bundleId)
            let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            iconByBundle[bundleId] = image
            return image
        }
        guard let path, !path.isEmpty else { return nil }
        if let cached = iconByPath[path] { return cached }
        let image = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : nil
        iconByPath[path] = image
        return image
    }

    func displayName(bundleId: String?, fallback: String) -> String {
        guard let bundleId, let url = applicationURL(bundleId: bundleId) else { return fallback }
        return FileManager.default.displayName(atPath: url.path)
    }

    func applicationURL(bundleId: String) -> URL? {
        if let cached = urlByBundle[bundleId] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        urlByBundle[bundleId] = url
        return url
    }

    /// Drops cache entries for keys that no longer exist.  Runs every 60 ticks
    /// so a long session does not accumulate dead processes.
    func pruneIfNeeded(live: Set<ProcessKey>) {
        ticksSincePrune += 1
        guard ticksSincePrune >= 60 else { return }
        ticksSincePrune = 0
        cache = cache.filter { live.contains($0.key) }
    }
}

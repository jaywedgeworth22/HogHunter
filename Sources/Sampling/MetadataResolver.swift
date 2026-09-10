import AppKit
import Foundation

/// The part of `NSRunningApplication` the resolver reads.  It exists so a test
/// can prove the table is read once per pid rather than once per tick.
protocol RunningApplicationInfo {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var localizedName: String? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var bundleURL: URL? { get }
}

extension NSRunningApplication: RunningApplicationInfo {}

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
        /// True when this entry was built from an `AppInfo` that had not yet
        /// settled (a nil bundle id, name or URL) -- a freshly launched app
        /// publishing itself asynchronously.  A provisional entry is never
        /// served from the cache, so the resolver keeps re-reading it every
        /// call until the app settles, at which point it is overwritten with
        /// a normal, cached entry.
        var isProvisional: Bool = false
    }

    /// What `NSWorkspace.runningApplications` knows about one process.  Reading
    /// these four properties is not free -- measured at 40-50 ms for ~250 apps
    /// on an M5 -- so an entry is built once per pid and reused for as long as
    /// that pid is still running.
    struct AppInfo {
        var bundleId: String?
        var localizedName: String?
        var activationPolicy: NSApplication.ActivationPolicy
        var bundleURL: URL?

        /// A freshly launched app publishes these asynchronously, so a partly
        /// filled entry is re-read next tick instead of being frozen.
        var isSettled: Bool { bundleId != nil && localizedName != nil && bundleURL != nil }
    }

    private(set) var runningApps: [pid_t: AppInfo] = [:]
    private var cache: [ProcessKey: Metadata] = [:]
    private var iconByBundle: [String: NSImage?] = [:]
    private var iconByPath: [String: NSImage?] = [:]
    private var urlByBundle: [String: URL?] = [:]
    private var nameByBundle: [String: String] = [:]
    private let enumerate: () -> [RunningApplicationInfo]

    init(runningApplications: @escaping () -> [RunningApplicationInfo] = { NSWorkspace.shared.runningApplications }) {
        self.enumerate = runningApplications
    }

    /// Refreshes the running-application table and returns it.  Enumerating is
    /// cheap; reading each app's properties is not, so a pid already in the
    /// table keeps the entry it had once it is settled.  A recycled pid can
    /// therefore carry the previous app's name for one tick, which is the same
    /// risk the per-key metadata cache already takes and is invisible at a 3 s
    /// cadence.  A settled entry's `activationPolicy` can still legitimately
    /// change later (an accessory helper promoted to regular, and vice versa),
    /// so the caller periodically passes `force: true` to re-read every app
    /// rather than trust the memo forever.
    @discardableResult
    func refreshRunningApps(force: Bool = false) -> [pid_t: AppInfo] {
        var table: [pid_t: AppInfo] = [:]
        table.reserveCapacity(runningApps.count)
        for app in enumerate() {
            let pid = app.processIdentifier
            if !force, let known = runningApps[pid], known.isSettled {
                table[pid] = known
                continue
            }
            table[pid] = AppInfo(
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
    /// without touching AppKit again -- unless that entry is `isProvisional`,
    /// in which case the cache is bypassed and the key is re-read until the
    /// app it belongs to settles.  Without this, a key first resolved while
    /// its app was still launching would keep serving that half-published
    /// entry (often just "pid 1234") forever, never picking up the real name
    /// once `NSRunningApplication` finishes publishing it.
    func resolve(_ keys: [ProcessKey], samples: [ProcessKey: ProcessSample]) -> [ProcessKey: Metadata] {
        var out: [ProcessKey: Metadata] = [:]
        out.reserveCapacity(keys.count)
        for key in keys {
            if let cached = cache[key], !cached.isProvisional {
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
                isRunningApplication: app != nil,
                isProvisional: app?.isSettled == false
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

    /// `FileManager.displayName(atPath:)` hits the file system, and the history
    /// rows ask for the same 25 bundle ids on every refresh, so the answer is
    /// cached.  Only the resolved name is cached: the fallback belongs to the
    /// caller's row, not to the bundle id.
    func displayName(bundleId: String?, fallback: String) -> String {
        guard let bundleId else { return fallback }
        if let cached = nameByBundle[bundleId] { return cached }
        guard let url = applicationURL(bundleId: bundleId) else { return fallback }
        let name = FileManager.default.displayName(atPath: url.path)
        nameByBundle[bundleId] = name
        return name
    }

    func applicationURL(bundleId: String) -> URL? {
        if let cached = urlByBundle[bundleId] { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        urlByBundle[bundleId] = url
        return url
    }

    /// Drops cache entries for keys that no longer exist.  The caller schedules
    /// this every 60 ticks; it does not throttle itself, so building the live
    /// set is only paid on the ticks that actually prune.  The bundle-keyed
    /// caches are deliberately not pruned: they are bounded by the number of
    /// distinct applications seen in one session, which is small.
    func prune(live: Set<ProcessKey>) {
        cache = cache.filter { live.contains($0.key) }
    }
}

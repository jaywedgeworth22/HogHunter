import Foundation
import UserNotifications

/// The decision half of alerting, with no notification machinery in it.
///
/// Feed it one `step` per row per tick.  It answers the only question that
/// matters: should this row fire right now?  A row must stay above the
/// threshold for `sustained` before it fires, dropping below resets that
/// clock, and after a firing the same row is quiet for `cooldown`.
struct AlertPolicy {
    /// How long a row must stay above the threshold before it fires.
    var sustained: TimeInterval
    /// How long a row stays quiet after firing.
    var cooldown: TimeInterval

    /// When each row first went above the threshold and stayed there.
    private var firstExceeded: [String: Date] = [:]
    /// When each row last fired.  Kept across a drop below the threshold, so a
    /// row that flaps cannot notify twice in one cooldown.
    private var lastFired: [String: Date] = [:]

    init(sustained: TimeInterval = 5 * 60, cooldown: TimeInterval = 30 * 60) {
        self.sustained = sustained
        self.cooldown = cooldown
    }

    /// True exactly on the tick where `id` earns a notification.
    mutating func step(id: String, above: Bool, now: Date) -> Bool {
        guard above else {
            firstExceeded[id] = nil
            return false
        }
        let start = firstExceeded[id] ?? now
        firstExceeded[id] = start
        guard now.timeIntervalSince(start) >= sustained else { return false }
        if let last = lastFired[id], now.timeIntervalSince(last) < cooldown { return false }
        lastFired[id] = now
        return true
    }

    /// How long `id` has been above the threshold, or 0 when it is not.
    func timeAboveThreshold(id: String, now: Date) -> TimeInterval {
        guard let start = firstExceeded[id] else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    /// Drops rows that are no longer on screen so a long session does not grow
    /// a dictionary entry per process it ever saw.
    mutating func forgetAll(except live: Set<String>) {
        firstExceeded = firstExceeded.filter { live.contains($0.0) }
        lastFired = lastFired.filter { live.contains($0.0) }
    }
}

/// Turns sustained CPU into one notification, and nothing else.
@MainActor
final class Alerts: ObservableObject {
    /// True once the user has said no.  Settings shows it next to the toggle.
    @Published private(set) var authorizationDenied = false
    /// The last thing the notification centre refused to do, if anything.
    @Published private(set) var lastError: String?

    private var policy = AlertPolicy()
    private var didRequestAuthorization = false

    /// Nil when there is no bundle to notify from, which is the case in unit
    /// tests and in any unbundled run.  Asking for the centre in that state
    /// traps, so it is never asked.
    private lazy var center: UNUserNotificationCenter? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }()

    /// Called when the setting is switched on.
    func requestAuthorization(completion: ((Bool) -> Void)? = nil) {
        guard let center else {
            authorizationDenied = true
            completion?(false)
            return
        }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.authorizationDenied = !granted
                if let error { self.lastError = error.localizedDescription }
                completion?(granted)
            }
        }
    }

    /// One pass over the visible rows.  Rows without live members are ignored,
    /// because a history row cannot still be hogging anything.
    func evaluate(
        rows: [HogRow],
        threshold: Double,
        sustained: TimeInterval,
        now: Date = Date()
    ) {
        policy.sustained = max(1, sustained)
        var live: Set<String> = []
        live.reserveCapacity(rows.count)
        for row in rows where !row.keys.isEmpty {
            live.insert(row.id)
            let above = row.cpuPercent >= threshold
            let elapsed = above ? policy.timeAboveThreshold(id: row.id, now: now) : 0
            guard policy.step(id: row.id, above: above, now: now) else { continue }
            notify(row: row, seconds: max(elapsed, policy.sustained))
        }
        policy.forgetAll(except: live)
    }

    /// "Chrome has used 412% for 5 minutes."
    static func message(name: String, cpuPercent: Double, seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let unit = minutes == 1 ? "minute" : "minutes"
        return "\(name) has used \(HogFormat.cpu(cpuPercent)) for \(minutes) \(unit)."
    }

    private func notify(row: HogRow, seconds: TimeInterval) {
        guard let center else { return }
        if !didRequestAuthorization { requestAuthorization() }
        let content = UNMutableNotificationContent()
        content.title = "Hog Hunter"
        content.body = Self.message(name: row.name, cpuPercent: row.cpuPercent, seconds: seconds)
        let request = UNNotificationRequest(
            identifier: "hog-\(row.id)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            guard let error else { return }
            DispatchQueue.main.async { [weak self] in
                self?.lastError = error.localizedDescription
            }
        }
    }
}

/// So `Alerts.AlertPolicy` resolves as well as the top-level name.
extension Alerts {
    typealias AlertPolicy = HogHunter.AlertPolicy
}

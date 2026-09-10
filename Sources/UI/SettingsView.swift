import AppKit
import SwiftUI

/// The Settings window.  Every control writes the same UserDefaults key the
/// store reads, so a change here reaches the panel on the next run loop turn
/// without either side owning the other.
struct SettingsView: View {
    @EnvironmentObject private var store: HogStore

    @AppStorage(HogStore.Key.refreshInterval) private var refreshInterval: Double = 3
    @AppStorage(HogStore.Key.menuBarLabelMode) private var menuBarLabelMode = MenuBarLabelMode.machinePercent.rawValue
    @AppStorage(HogStore.Key.cpuScale) private var cpuScale = CpuScale.perCore.rawValue
    @AppStorage(HogStore.Key.appearance) private var appearance = AppearanceChoice.light.rawValue
    @AppStorage(HogStore.Key.alertsEnabled) private var alertsEnabled = false
    @AppStorage(HogStore.Key.alertThresholdPercent) private var alertThreshold: Double = 300
    @AppStorage(HogStore.Key.alertSustainedMinutes) private var alertSustainedMinutes: Int = 5

    var body: some View {
        Form {
            general
            appearanceSection
            AlertsSection(
                alerts: store.alerts,
                enabled: $alertsEnabled,
                threshold: $alertThreshold,
                sustainedMinutes: $alertSustainedMinutes
            )
            loginSection
            about
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(AppearanceChoice(rawValue: appearance)?.colorScheme ?? .light)
        .background(SettingsWindowActivator())
        .onAppear { SettingsWindowActivator.front() }
    }

    // MARK: - General

    private var general: some View {
        Section("General") {
            Picker("Refresh Every", selection: $refreshInterval) {
                Text("2 Seconds").tag(2.0)
                Text("3 Seconds").tag(3.0)
                Text("5 Seconds").tag(5.0)
            }

            Picker("Menu Bar Shows", selection: $menuBarLabelMode) {
                ForEach(MenuBarLabelMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }

            Picker("CPU Scale", selection: $cpuScale) {
                ForEach(CpuScale.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            Text(scaleExplanation)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scaleExplanation: String {
        switch CpuScale(rawValue: cpuScale) ?? .perCore {
        case .perCore:
            return "Per Core matches Activity Monitor: 100% is one core fully busy, so a row can read 400%."
        case .machineShare:
            return "Share of Machine puts rows on the header's scale: 100% is every core fully busy."
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Theme", selection: $appearance) {
                ForEach(AppearanceChoice.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Light is the default.  System follows the Mac's own setting.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Launch at Login

    private var loginSection: some View {
        Section("Startup") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // The same name the panel's footer and the coverage note use.
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { _ in store.toggleLoginItem() }
                ))
                if let error = store.loginItemError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("History only covers the time Hog Hunter has been running.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - About

    private var about: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Self.versionString)
                    .monospacedDigit()
            }
            Button("Open Activity Monitor") { HogActions.openActivityMonitor() }
                .buttonStyle(.link)
        }
    }

    static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Alerts

/// Its own view so it can observe `Alerts` directly and redraw when the
/// authorization answer comes back.
private struct AlertsSection: View {
    @ObservedObject var alerts: Alerts
    @Binding var enabled: Bool
    @Binding var threshold: Double
    @Binding var sustainedMinutes: Int

    var body: some View {
        Section("Alerts") {
            Toggle("Notify Me About Sustained Hogs", isOn: $enabled)

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: $threshold, in: 100...1000, step: 50) {
                    Text("CPU Above")
                } minimumValueLabel: {
                    Text("100%")
                } maximumValueLabel: {
                    Text("1000%")
                }
                Text(thresholdExplanation)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .disabled(!enabled)

            Stepper(value: $sustainedMinutes, in: 1...30) {
                Text("For \(sustainedMinutes) \(sustainedMinutes == 1 ? "minute" : "minutes")")
            }
            .disabled(!enabled)

            if enabled, alerts.authorizationDenied {
                Text("Notifications are off for Hog Hunter in System Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The threshold is always stated on the per-core scale, whatever the rows
    /// are showing, because that is the number the alert compares against.
    private var thresholdExplanation: String {
        let cores = threshold / 100
        let coreText = cores == cores.rounded()
            ? String(format: "%.0f", cores)
            : String(format: "%.1f", cores)
        let plural = cores == 1 ? "core" : "cores"
        return "\(HogFormat.cpu(threshold)) of one core — about \(coreText) \(plural) fully busy."
    }
}

// MARK: - Window activation

/// A MenuBarExtra app has no Dock icon, so the Settings window can open behind
/// whatever the user was looking at.  This brings it forward whenever it is
/// attached to a window.
private struct SettingsWindowActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ActivatingView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func front() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    final class ActivatingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.isVisible else { return }
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

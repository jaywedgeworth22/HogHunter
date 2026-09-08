import AppKit
import SwiftUI

struct HogHunterPanel: View {
    @EnvironmentObject private var store: HogStore
    @State private var pendingQuit: HogRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            meters
            captions
            controls
            list
            footer
        }
        .padding(14)
        .frame(width: 400, height: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
        .onAppear { store.panelVisible = true }
        .onDisappear { store.panelVisible = false }
        .alert(
            pendingQuit.map { "Quit \($0.name)?" } ?? "Quit Process?",
            isPresented: Binding(
                get: { pendingQuit != nil },
                set: { if !$0 { pendingQuit = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingQuit = nil }
            Button("Quit") {
                if let row = pendingQuit { store.quit(row, force: false) }
                pendingQuit = nil
            }
            Button("Force Quit", role: .destructive) {
                if let row = pendingQuit { store.quit(row, force: true) }
                pendingQuit = nil
            }
        } message: {
            Text(quitMessage)
        }
    }

    private var quitMessage: String {
        guard let row = pendingQuit else { return "" }
        let count = max(1, row.keys.count)
        return "Asks \(row.name) to quit.  It may show a save prompt or refuse.  "
            + "\(count) processes are included."
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color(red: 0.86, green: 0.32, blue: 0.16))
            Text("Hog Hunter")
                .font(.system(size: 18, weight: .semibold))
            if store.isStale {
                Circle()
                    .fill(Color(red: 0.80, green: 0.52, blue: 0.10))
                    .frame(width: 7, height: 7)
                    .help("Sampling is behind.")
                    .accessibilityLabel("Sampling is behind")
            }
            Spacer()
        }
    }

    // MARK: - Meters

    private var meters: some View {
        HStack(spacing: 10) {
            Meter(
                title: "CPU",
                value: store.pulse.cpuPercent,
                caption: store.hasBaseline ? store.cpuCaption : "Measuring…",
                tint: Severity.forMachineCpu(store.pulse.cpuPercent).color
            )
            Meter(
                title: "Memory",
                value: store.pulse.memoryPercent,
                caption: store.memoryCaption,
                tint: Severity.forPressure(store.pulse.pressure).color
            )
        }
    }

    private var captions: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.hasBaseline ? store.attributionCaption : "Measuring…  The first CPU reading needs two samples.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let swapping = store.swapRateCaption {
                Text(swapping)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Window", selection: $store.window) {
                ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack {
                Picker("Show", selection: $store.grouping) {
                    ForEach(HogGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Sort", selection: $store.sort) {
                    ForEach(HogSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }
        }
        .labelsHidden()
    }

    // MARK: - Rows

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.rows.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                ForEach(store.rows) { row in
                    HogRowView(
                        row: row,
                        scale: store.cpuScale,
                        coreCount: store.pulse.coreCount
                    ) {
                        pendingQuit = row
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !store.hasBaseline { return "Measuring…" }
        if store.window == .now { return "Nothing heavy right now." }
        return "No history yet.  Leave Hog Hunter open to build it."
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(store.coverageNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(store.scaleLegend)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            HStack {
                Toggle("Launch at Login", isOn: Binding(
                    get: { store.launchesAtLogin },
                    set: { _ in store.toggleLoginItem() }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                Spacer()
                Button("Activity Monitor") {
                    NSWorkspace.shared.open(
                        URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
                    )
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                Button("Quit Hog Hunter") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
            }
        }
    }
}

private struct Meter: View {
    let title: String
    let value: Double
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(tint)
                .accessibilityLabel(title)
                .accessibilityValue(caption)
            Text(caption)
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct HogRowView: View {
    let row: HogRow
    let scale: CpuScale
    let coreCount: Int
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(HogFormat.cpu(row.cpuPercent, scale: scale, coreCount: coreCount))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Severity.forProcessCpu(row.cpuPercent).color)
                Text(HogFormat.memory(row.memoryBytes))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if row.canQuit {
                Button("Quit", action: onQuit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Quit This Process")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.7)))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        } else {
            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }
}

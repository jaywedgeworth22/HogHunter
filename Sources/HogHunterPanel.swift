import AppKit
import SwiftUI

struct HogHunterPanel: View {
    @EnvironmentObject private var store: HogStore
    @State private var pendingQuit: HogRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            meters
            controls
            Text(store.coverageNote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.lastError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            list
            footer
        }
        .padding(14)
        .frame(width: 400, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
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
            Text("This sends a quit signal to the selected process.  Force Quit cannot be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "flame.fill")
                .foregroundStyle(Color(red: 0.86, green: 0.32, blue: 0.16))
            Text("Hog Hunter")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
        }
    }

    private var meters: some View {
        HStack(spacing: 10) {
            Meter(title: "CPU", value: store.pulse.cpuPercent, caption: HogFormat.cpu(store.pulse.cpuPercent))
            Meter(
                title: "Memory",
                value: store.pulse.memoryPercent,
                caption: "\(HogFormat.memory(store.pulse.usedMemoryBytes)) of \(HogFormat.memory(store.pulse.totalMemoryBytes))"
            )
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Window", selection: $store.window) {
                ForEach(TimeWindow.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.window) { _, _ in store.rebuildRows() }

            HStack {
                Picker("Show", selection: $store.grouping) {
                    ForEach(HogGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: store.grouping) { _, _ in store.rebuildRows() }

                Picker("Sort", selection: $store.sort) {
                    ForEach(HogSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: store.sort) { _, _ in store.rebuildRows() }
            }
        }
        .labelsHidden()
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if store.rows.isEmpty {
                    Text(store.window == .now ? "Nothing heavy right now." : "No history yet.  Leave Hog Hunter open to build it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                ForEach(store.rows) { row in
                    HogRowView(row: row) {
                        pendingQuit = row
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at Login", isOn: Binding(
                get: { store.launchesAtLogin },
                set: { _ in store.toggleLoginItem() }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
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

private struct Meter: View {
    let title: String
    let value: Double
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(value > 85 ? Color(red: 0.75, green: 0.18, blue: 0.16) : Color(red: 0.18, green: 0.42, blue: 0.78))
            Text(caption)
                .font(.system(size: 11, design: .rounded).monospacedDigit())
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
                Text(HogFormat.cpu(row.cpuPercent))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                Text(HogFormat.memory(row.memoryBytes))
                    .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if row.canKill {
                Button("Quit", action: onQuit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Quit This Process")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.7)))
    }

    @ViewBuilder
    private var icon: some View {
        if let image = row.icon {
            Image(nsImage: image)
                .resizable()
                .frame(width: 22, height: 22)
        } else {
            Image(systemName: row.isApp ? "app.fill" : "gearshape")
                .frame(width: 22, height: 22)
                .foregroundStyle(.secondary)
        }
    }
}

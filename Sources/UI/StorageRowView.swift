import SwiftUI

/// One row in the Storage pane.  The collapsed form shows the icon, name,
/// total disk, and the bundle-vs-hidden split.  The expanded form adds a
/// per-category breakdown that mirrors what the scanner wrote into the row.
struct StorageRowView: View {
    let usage: StorageUsage
    let isExpanded: Bool
    let onToggle: () -> Void

    private static let rowHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isExpanded {
                Divider()
                breakdown
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isExpanded ? 0.07 : 0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(usage.isHiddenHeavy ? Color.red.opacity(0.6) : Color.primary.opacity(0.05),
                        lineWidth: usage.isHiddenHeavy ? 1.0 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .center, spacing: 10) {
            iconView
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(usage.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    if usage.isRunning {
                        Text("running")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                    }
                    if usage.isHiddenHeavy {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: 10))
                            .help("Hidden cost is much larger than the .app bundle.")
                    }
                }
                Text(splitCaption)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(HogFormat.memory(usage.totalBytes))
                .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: Self.rowHeight)
    }

    private var splitCaption: String {
        let bundle = HogFormat.memory(usage.bundleBytes)
        let hidden = HogFormat.memory(usage.hiddenBytes)
        var pieces: [String] = ["bundle \(bundle)"]
        if usage.hiddenBytes > 0 {
            pieces.append("hidden \(hidden)")
        }
        var caption = pieces.joined(separator: " · ")
        if usage.anyApproximate {
            caption += " · approximate"
        }
        return caption
    }

    private var iconView: some View {
        Group {
            if let path = usage.path,
               let icon = NSWorkspace.shared.icon(forFile: path) as NSImage? {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Breakdown

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let path = usage.path {
                Text(path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let bundleId = usage.bundleId {
                Text("Bundle id: \(bundleId)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            ForEach(usage.slices, id: \.category) { slice in
                HStack(spacing: 6) {
                    Image(systemName: icon(for: slice.category))
                        .font(.system(size: 10))
                        .frame(width: 14)
                        .foregroundStyle(.secondary)
                    Text(slice.category.displayName)
                        .font(.system(size: 11))
                    if slice.approximate {
                        Text("(approx.)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(HogFormat.memory(slice.bytes))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Reveal in Finder") {
                    if let path = usage.path {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .padding(.leading, 38)
    }

    private func icon(for category: StorageCategory) -> String {
        switch category {
        case .bundle: return "app.bundle"
        case .containers: return "shippingbox"
        case .groupContainers: return "person.2"
        case .applicationSupport: return "folder"
        case .caches: return "trash"
        case .webKit: return "globe"
        case .preferences: return "slider.horizontal.3"
        case .savedState: return "clock.arrow.circlepath"
        case .logs: return "doc.text"
        case .cookies: return "key"
        case .httpStorage: return "network"
        case .appScripts: return "curlybraces"
        case .other: return "questionmark.circle"
        }
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        var pieces = [usage.name, HogFormat.memory(usage.totalBytes), "on disk"]
        if usage.isHiddenHeavy { pieces.append("hidden cost much larger than bundle") }
        if let bundleId = usage.bundleId { pieces.append("bundle id \(bundleId)") }
        return pieces.joined(separator: ", ")
    }
}

import SwiftUI

/// A headline number: a labeled bar, tinted by severity, with a caption under
/// it.  The whole thing reads as one element to VoiceOver: the title is the
/// label and the caption is the value.
struct Meter: View {
    let title: String
    /// 0-100.  Values outside the range are clamped for the bar.
    let value: Double
    let caption: String
    let severity: Severity
    /// Spoken instead of `caption` when the visible caption is abbreviated.
    var accessibilityDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ProgressView(value: min(max(value / 100, 0), 1))
                .tint(severity.color)
            Text(caption)
                .font(.system(size: 11, design: .rounded).monospacedDigit())
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityDetail ?? caption)
    }
}

/// A secondary fact that sits under a meter: swap, memory pressure, thermal
/// state.  Small, tinted by severity, and never competing with the meter.
struct MeterPill: View {
    let text: String
    var severity: Severity = .calm
    var help: String?

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .multilineTextAlignment(.center)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 0.5)
            )
            .help(help ?? text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// Calm facts stay neutral; only a warning earns a color.
    private var tint: Color {
        severity == .calm ? Color.secondary : severity.color
    }

    private var fill: Color {
        severity == .calm ? Color.primary.opacity(0.06) : severity.color.opacity(0.12)
    }
}

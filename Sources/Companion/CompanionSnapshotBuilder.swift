import Foundation

/// Builds the phone snapshot from the rows the Mac panel is already showing.
enum CompanionSnapshotBuilder {
    static func make(
        hostName: String,
        sampledAt: Date,
        hasBaseline: Bool,
        window: TimeWindow,
        grouping: HogGrouping,
        scale: CpuScale,
        pulse: MachinePulse,
        rows: [HogRow]
    ) -> CompanionSnapshot {
        let cores = max(1, pulse.coreCount)
        let pressure = Severity.forPressure(pulse.pressure)
        return CompanionSnapshot(
            version: CompanionService.version,
            hostName: hostName,
            sampledAt: sampledAt,
            hasBaseline: hasBaseline,
            window: window.rawValue,
            grouping: grouping.rawValue,
            cpuScale: scale.rawValue,
            pulse: CompanionPulse(
                cpuPercent: pulse.cpuPercent,
                cpuText: hasBaseline ? HogFormat.percent(pulse.cpuPercent / 100) : "Measuring…",
                cpuCaption: "of all \(cores) cores",
                cpuSeverity: severityName(Severity.forMachineCpu(pulse.cpuPercent)),
                memoryPercent: pulse.memoryPercent,
                memoryText: "\(gigabytes(pulse.memoryUsedBytes)) of \(gigabytes(pulse.totalMemoryBytes)) GB",
                memoryCaption: "Memory in use",
                swapText: pulse.swapUsedBytes > 0 ? "\(HogFormat.memory(pulse.swapUsedBytes)) swapped" : nil,
                pressureText: pulse.pressure == .unknown ? nil : "Pressure \(pulse.pressure.label)",
                pressureSeverity: severityName(pressure)
            ),
            rows: rows.map { row in
                let display = displayedCPU(row.cpuPercent, scale: scale, coreCount: cores)
                let severity = Severity.forProcessCpu(display, scale: scale, coreCount: cores)
                return CompanionRow(
                    id: row.id,
                    name: row.name,
                    detail: row.detail,
                    cpuText: HogFormat.cpu(row.cpuPercent, scale: scale, coreCount: cores),
                    memoryText: HogFormat.memory(row.memoryBytes),
                    severity: severityName(severity),
                    isApp: row.isApp
                )
            }
        )
    }

    private static func displayedCPU(_ perCore: Double, scale: CpuScale, coreCount: Int) -> Double {
        switch scale {
        case .perCore:
            return perCore
        case .machineShare:
            return perCore / Double(max(1, coreCount))
        }
    }

    private static func severityName(_ severity: Severity) -> String {
        switch severity {
        case .calm: return "calm"
        case .elevated: return "elevated"
        case .hot: return "hot"
        }
    }

    /// Same rounding the Mac memory caption uses: integer when the value is whole.
    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_073_741_824
        let posix = Locale(identifier: "en_US_POSIX")
        if value == value.rounded() {
            return String(format: "%.0f", locale: posix, value)
        }
        return String(format: "%.1f", locale: posix, value)
    }
}

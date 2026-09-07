import AppKit
import Foundation

enum TimeWindow: String, CaseIterable, Identifiable {
    case now = "Now"
    case hour = "Past Hour"
    case day = "Past 24 Hours"

    var id: String { rawValue }

    var lookback: TimeInterval? {
        switch self {
        case .now: return nil
        case .hour: return 60 * 60
        case .day: return 24 * 60 * 60
        }
    }
}

enum HogSort: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"

    var id: String { rawValue }
}

enum HogGrouping: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case processes = "Processes"

    var id: String { rawValue }
}

struct HogRow: Identifiable, Hashable {
    var id: String
    var pid: Int32
    var pids: [Int32]
    var name: String
    var detail: String
    var cpuPercent: Double
    var memoryBytes: UInt64
    var icon: NSImage?
    var isApp: Bool
    var canKill: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HogRow, rhs: HogRow) -> Bool {
        lhs.id == rhs.id
            && lhs.cpuPercent == rhs.cpuPercent
            && lhs.memoryBytes == rhs.memoryBytes
            && lhs.pids == rhs.pids
    }
}

struct MachinePulse: Equatable {
    var cpuPercent: Double
    var usedMemoryBytes: UInt64
    var totalMemoryBytes: UInt64
    var processCount: Int

    var memoryPercent: Double {
        guard totalMemoryBytes > 0 else { return 0 }
        return Double(usedMemoryBytes) / Double(totalMemoryBytes) * 100
    }
}

enum HogFormat {
    static func cpu(_ value: Double) -> String {
        if value < 0.05 { return "0%" }
        if value < 10 { return String(format: "%.1f%%", value) }
        return String(format: "%.0f%%", value)
    }

    static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        if mb >= 10 {
            return String(format: "%.0f MB", mb)
        }
        if mb >= 1 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

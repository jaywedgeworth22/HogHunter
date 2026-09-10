import XCTest

@testable import HogHunter

/// Covers `HogStore.alertCandidates(processes:groups:grouping:threshold:...)`,
/// the pure selection half of alerting lifted out of the store so it can be
/// exercised without a `HogStore` (no resolver, no samples dictionary, no main
/// actor).  The scenario in every test here is the one the 1.1 review flagged:
/// a process or app that is small in footprint but burning CPU must still be
/// selected, even sitting among many large, idle ones -- exactly what the
/// panel's own 25-row, Sort-ordered display list would drop.
final class AlertCandidatesTests: XCTestCase {

    private let threshold: Double = 300

    /// A minimal `ProcessSample` factory, matching the one in
    /// `GroupingTests.swift`: only the fields a caller here cares about are
    /// parameters, the rest take inert defaults.
    private func sample(
        pid: pid_t,
        name: String,
        cpu: Double,
        memory: UInt64
    ) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: 0),
            ppid: 1,
            uid: 501,
            name: name,
            path: "",
            cpuPercent: cpu,
            hasBaseline: true,
            footprintBytes: memory,
            residentBytes: memory,
            threadCount: 1,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            idleWakeupsPerSec: 0
        )
    }

    /// A minimal single-member `Grouping.Group` factory: enough to drive the
    /// `.apps` branch of selection without going through `Grouping.groups`
    /// itself, which is covered separately in `GroupingTests.swift`.
    private func group(
        key: String,
        name: String,
        cpu: Double,
        memory: UInt64,
        pid: pid_t
    ) -> Grouping.Group {
        let member = sample(pid: pid, name: name, cpu: cpu, memory: memory)
        return Grouping.Group(
            key: key,
            ownerPid: pid,
            bundleId: nil,
            name: name,
            path: nil,
            members: [member],
            cpuPercent: cpu,
            memoryBytes: memory,
            isApp: true
        )
    }

    private func processRowId(_ key: ProcessKey) -> String { "p-\(key.pid)-\(key.startTime)" }
    private func groupRowId(_ key: String) -> String { "a-\(key)" }

    // MARK: - .processes

    func testProcessesGroupingSelectsOnlyTheSmallHighCpuOutlier() {
        // 30 large, idle decoys plus one small process pinning five cores.
        var processes: [ProcessSample] = (0..<30).map { i in
            sample(pid: pid_t(1_000 + i), name: "Decoy\(i)", cpu: 10, memory: 2_000_000_000)
        }
        let hog = sample(pid: 2_000, name: "Hog", cpu: 500, memory: 1_000_000)
        processes.append(hog)

        let selections = HogStore.alertCandidates(
            processes: processes,
            groups: [],
            grouping: .processes,
            threshold: threshold,
            processRowId: processRowId,
            groupRowId: groupRowId
        )

        XCTAssertEqual(selections.count, 1, "only the process above threshold must be selected")
        XCTAssertEqual(selections.first?.candidate.id, processRowId(hog.key))
        XCTAssertEqual(selections.first?.candidate.cpuPercent, 500)
        XCTAssertEqual(selections.first?.resolveKey, hog.key)

        let selectedIds = Set(selections.map(\.candidate.id))
        for decoy in processes where decoy.key != hog.key {
            XCTAssertFalse(
                selectedIds.contains(processRowId(decoy.key)),
                "a decoy below threshold must never be selected"
            )
        }
    }

    // MARK: - .apps

    func testAppsGroupingSelectsOnlyTheSmallHighCpuOutlier() {
        // 30 large, idle decoy groups plus one small group pinning five cores.
        var groups: [Grouping.Group] = (0..<30).map { i in
            group(key: "decoy\(i)", name: "Decoy\(i)", cpu: 10, memory: 2_000_000_000, pid: pid_t(1_000 + i))
        }
        let hog = group(key: "hog", name: "Hog", cpu: 500, memory: 1_000_000, pid: 2_000)
        groups.append(hog)

        let selections = HogStore.alertCandidates(
            processes: [],
            groups: groups,
            grouping: .apps,
            threshold: threshold,
            processRowId: processRowId,
            groupRowId: groupRowId
        )

        XCTAssertEqual(selections.count, 1, "only the group above threshold must be selected")
        XCTAssertEqual(selections.first?.candidate.id, groupRowId(hog.key))
        XCTAssertEqual(selections.first?.candidate.cpuPercent, 500)
        XCTAssertEqual(selections.first?.resolveKey, hog.members[0].key, "the anchor is the group's sole, owning member")

        let selectedIds = Set(selections.map(\.candidate.id))
        for decoy in groups where decoy.key != hog.key {
            XCTAssertFalse(
                selectedIds.contains(groupRowId(decoy.key)),
                "a decoy group below threshold must never be selected"
            )
        }
    }

    func testNothingIsSelectedWhenEveryRowIsBelowThreshold() {
        let processes: [ProcessSample] = (0..<30).map { i in
            sample(pid: pid_t(1_000 + i), name: "Decoy\(i)", cpu: 10, memory: 2_000_000_000)
        }

        let selections = HogStore.alertCandidates(
            processes: processes,
            groups: [],
            grouping: .processes,
            threshold: threshold,
            processRowId: processRowId,
            groupRowId: groupRowId
        )

        XCTAssertTrue(selections.isEmpty)
    }
}

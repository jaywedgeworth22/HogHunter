import AppKit
import XCTest

@testable import HogHunter

/// A stand-in for `NSRunningApplication` that counts how often the resolver
/// reads its properties.  Those four reads are the expensive part of a refresh
/// -- measured at 40-50 ms for ~250 running apps -- so the point of these tests
/// is that they happen once per pid, not once per tick.
private final class FakeRunningApp: RunningApplicationInfo {
    let processIdentifier: pid_t
    private let storedBundleId: String?
    private let storedName: String?
    private let storedPolicy: NSApplication.ActivationPolicy
    private let storedURL: URL?
    private(set) var propertyReads = 0

    init(
        pid: pid_t,
        bundleId: String?,
        name: String?,
        policy: NSApplication.ActivationPolicy,
        url: URL?
    ) {
        self.processIdentifier = pid
        self.storedBundleId = bundleId
        self.storedName = name
        self.storedPolicy = policy
        self.storedURL = url
    }

    var bundleIdentifier: String? {
        propertyReads += 1
        return storedBundleId
    }

    var localizedName: String? {
        propertyReads += 1
        return storedName
    }

    var activationPolicy: NSApplication.ActivationPolicy {
        propertyReads += 1
        return storedPolicy
    }

    var bundleURL: URL? {
        propertyReads += 1
        return storedURL
    }
}

final class MetadataResolverTests: XCTestCase {

    private func app(pid: pid_t, bundleId: String? = "com.example.Editor") -> FakeRunningApp {
        FakeRunningApp(
            pid: pid,
            bundleId: bundleId,
            name: "Editor",
            policy: .regular,
            url: URL(fileURLWithPath: "/Applications/Editor.app")
        )
    }

    private func sample(pid: pid_t, start: UInt64, name: String) -> ProcessSample {
        ProcessSample(
            key: ProcessKey(pid: pid, startTime: start),
            ppid: 1,
            uid: 501,
            name: name,
            path: "",
            cpuPercent: 0,
            hasBaseline: true,
            footprintBytes: 0,
            residentBytes: 0,
            threadCount: 1,
            diskReadBytesPerSec: 0,
            diskWriteBytesPerSec: 0,
            idleWakeupsPerSec: 0
        )
    }

    // MARK: - Running-app table

    @MainActor
    func testRunningApplicationPropertiesAreReadOncePerPid() {
        let editor = app(pid: 501)
        let resolver = MetadataResolver(runningApplications: { [editor] })

        resolver.refreshRunningApps()
        XCTAssertEqual(editor.propertyReads, 4, "one read of each property on first sight")
        XCTAssertTrue(resolver.isRegularApp(501))
        XCTAssertEqual(resolver.bundleId(501), "com.example.Editor")

        for _ in 0..<20 { resolver.refreshRunningApps() }
        XCTAssertEqual(editor.propertyReads, 4, "a pid already in the table must not be read again")
        XCTAssertTrue(resolver.isRegularApp(501), "the memoized entry still answers")
        XCTAssertEqual(resolver.bundleId(501), "com.example.Editor")
    }

    @MainActor
    func testAnAppThatHasNotPublishedItselfYetIsReadAgain() {
        // NSRunningApplication fills these in asynchronously after a launch, so
        // a half-published entry must not be frozen.
        let launching = FakeRunningApp(pid: 777, bundleId: nil, name: nil, policy: .prohibited, url: nil)
        let resolver = MetadataResolver(runningApplications: { [launching] })

        resolver.refreshRunningApps()
        XCTAssertEqual(launching.propertyReads, 4)
        resolver.refreshRunningApps()
        XCTAssertEqual(launching.propertyReads, 8, "an unsettled entry is re-read next tick")
    }

    @MainActor
    func testPidsThatHaveGoneLeaveTheTable() {
        let editor = app(pid: 501)
        var running: [RunningApplicationInfo] = [editor]
        let resolver = MetadataResolver(runningApplications: { running })

        resolver.refreshRunningApps()
        XCTAssertEqual(resolver.runningApps.count, 1)

        running = []
        resolver.refreshRunningApps()
        XCTAssertTrue(resolver.runningApps.isEmpty)
        XCTAssertNil(resolver.bundleId(501))
    }

    // MARK: - Per-key cache

    @MainActor
    func testPruneDropsMetadataForKeysThatAreGone() {
        let resolver = MetadataResolver(runningApplications: { [] })
        let key = ProcessKey(pid: 900, startTime: 7)

        let first = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "first")])
        XCTAssertEqual(first[key]?.displayName, "first")

        let cached = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "second")])
        XCTAssertEqual(cached[key]?.displayName, "first", "a cached key is answered without touching AppKit")

        resolver.prune(live: [])
        let rebuilt = resolver.resolve([key], samples: [key: sample(pid: 900, start: 7, name: "second")])
        XCTAssertEqual(rebuilt[key]?.displayName, "second", "pruning really drops the entry")
    }
}

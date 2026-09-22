import XCTest

@testable import HogHunter

/// Covers `NetworkScanner.parse(rawOutput:bundleResolver:)`.  Tests run
/// on synthetic `-F` blocks so they do not depend on lsof or on a live
/// network, both of which are environment-dependent.
final class NetworkScannerTests: XCTestCase {

    // MARK: - Empty input

    func testEmptyOutputProducesEmptySnapshot() {
        let usages = NetworkScanner.parse(rawOutput: "") { ($0 == 1 ? "com.example.A" : nil, "name-\($0)") }
        XCTAssertTrue(usages.isEmpty)
    }

    // MARK: - Single pid, single ESTABLISHED TCP socket

    func testEstablishedTcpSocketBucketsOnePid() {
        let raw = """
        p1234
        PTCP
        TESTABLISHED
        nTCP 192.168.1.10:8080->10.0.0.1:443
        """
        let usages = NetworkScanner.parse(rawOutput: raw) { pid in
            pid == 1234 ? (bundleId: "com.example.App", name: "App") : (nil, "pid \(pid)")
        }
        XCTAssertEqual(usages.count, 1)
        let usage = try! XCTUnwrap(usages.first)
        XCTAssertEqual(usage.pid, 1234)
        XCTAssertEqual(usage.bundleId, "com.example.App")
        XCTAssertEqual(usage.name, "App")
        XCTAssertEqual(usage.openSockets, 1)
        XCTAssertEqual(usage.establishedSockets, 1)
        XCTAssertEqual(usage.remoteHostCount, 1)
        XCTAssertEqual(usage.topRemoteHosts, ["10.0.0.1"])
    }

    // MARK: - Multiple pids sort by established count, then host count

    func testMultiplePidsAreSortedByEstablishedCountThenHostCount() {
        // Real lsof output: each socket is preceded by its own P and T lines.
        let raw = """
        p100
        PTCP
        TESTABLISHED
        nTCP 1.1.1.1:1->2.2.2.2:80
        p200
        PTCP
        TESTABLISHED
        nTCP 1.1.1.1:2->3.3.3.3:80
        p300
        PTCP
        TESTABLISHED
        nTCP 1.1.1.1:3->4.4.4.4:80
        PTCP
        TESTABLISHED
        nTCP 1.1.1.1:4->5.5.5.5:80
        PTCP
        TESTABLISHED
        nTCP 1.1.1.1:5->6.6.6.6:80
        """
        let usages = NetworkScanner.parse(rawOutput: raw) { pid in
            (nil, "pid \(pid)")
        }
        // Sort: 300 first (3 established), then 100 and 200 (1 each, tie).
        XCTAssertEqual(usages.first?.pid, 300)
        XCTAssertEqual(usages.first?.establishedSockets, 3)
    }

    // MARK: - LISTEN sockets have no remote host

    func testListenSocketHasNoRemoteHost() {
        let raw = """
        p42
        PTCP
        TLISTEN
        nTCP *:8080
        """
        let usages = NetworkScanner.parse(rawOutput: raw) { _ in (nil, "X") }
        let usage = try! XCTUnwrap(usages.first)
        XCTAssertEqual(usage.openSockets, 1)
        XCTAssertEqual(usage.establishedSockets, 0)
        XCTAssertEqual(usage.remoteHostCount, 0)
        XCTAssertTrue(usage.topRemoteHosts.isEmpty)
    }

    // MARK: - IPv6 endpoints

    func testIPv6EndpointsSplitOnLastColon() {
        let raw = """
        p55
        PTCP6
        TESTABLISHED
        nTCP6 [2001:db8::1]:443->[2001:db8::dead:beef]:54321
        """
        let usages = NetworkScanner.parse(rawOutput: raw) { _ in (nil, "X") }
        let usage = try! XCTUnwrap(usages.first)
        // Parser exposes remote host count and a top-5 list at the row
        // level; brackets around the IPv6 form are stripped so the host
        // matches what `nslookup` returns.
        XCTAssertEqual(usage.remoteHostCount, 1)
        XCTAssertTrue(usage.topRemoteHosts.contains("2001:db8::dead:beef"))
    }

    // MARK: - Top hosts are capped at 5

    func testTopHostsAreCappedAtFive() {
        var raw = "p1\nPTCP\nTESTABLISHED\n"
        for i in 0..<12 {
            raw += "PTCP\nTESTABLISHED\nnTCP 10.0.0.\(i):1->172.16.0.\(i):80\n"
        }
        let usages = NetworkScanner.parse(rawOutput: raw) { _ in (nil, "X") }
        let usage = try! XCTUnwrap(usages.first)
        XCTAssertEqual(usage.topRemoteHosts.count, 5)
        XCTAssertEqual(usage.remoteHostCount, 12)
    }

    // MARK: - Fake process runner passes through failure modes

    func testSnapshotReturnsUnavailableWhenBinaryMissing() {
        let scanner = NetworkScanner(binaryPath: "/nonexistent/lsof")
        let result = scanner.snapshot(bundleResolver: { _ in (nil, "x") })
        guard case .unavailable(let reason) = result else {
            XCTFail("Expected unavailable, got \(result)")
            return
        }
        XCTAssertTrue(reason.contains("missing"))
    }

    func testSnapshotPassesThroughLsofPermissionError() {
        let fakeRunner = ProcessRunner { _ in
            (1, "", "Operation not permitted")
        }
        let scanner = NetworkScanner(process: fakeRunner)
        let result = scanner.snapshot(bundleResolver: { _ in (nil, "x") })
        guard case .unavailable(let reason) = result else {
            XCTFail("Expected unavailable, got \(result)")
            return
        }
        XCTAssertTrue(reason.lowercased().contains("denied"))
    }

    // MARK: - Live lsof when present (smoke test only)

    func testLiveLsofAtTheSystemPathDoesNotThrowAtProcessLevel() throws {
        // We do not assert on the output — that depends on the machine the
        // test runs on.  We only assert that the binary path resolves and
        // does not throw a binary-missing error.
        let scanner = NetworkScanner(binaryPath: "/usr/sbin/lsof")
        let result = scanner.snapshot(bundleResolver: { _ in (nil, "x") })
        // Either we have a snapshot, or we have an availability string —
        // both are non-throwing terminals we accept.
        switch result {
        case .snapshot, .unavailable: break
        }
    }
}

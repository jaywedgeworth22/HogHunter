import XCTest

@testable import HogHunter

final class ClaudeProcessTests: XCTestCase {
    func testSharedVersionsInstallIsRecognized() {
        XCTAssertTrue(ClaudeProcess.isCLI(path: "/Users/jay/.local/share/claude/versions/2.1.266"))
    }

    func testDesktopAppManagedCopyIsRecognized() {
        let path = "/Users/jay/Library/Application Support/Claude/claude-code/2.1.260/claude.app/Contents/MacOS/Claude Code"
        XCTAssertTrue(ClaudeProcess.isCLI(path: path))
    }

    func testUnrelatedExecutableIsNotRecognized() {
        XCTAssertFalse(ClaudeProcess.isCLI(path: "/usr/local/bin/node"))
    }

    func testEmptyPathIsNotRecognized() {
        XCTAssertFalse(ClaudeProcess.isCLI(path: ""))
    }
}

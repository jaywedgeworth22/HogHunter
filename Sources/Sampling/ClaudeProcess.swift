import Foundation

/// Identifies Claude Code's own CLI binary, however it happens to be
/// installed.  Claude Code ships each release as a version-numbered binary
/// (e.g. `~/.local/share/claude/versions/2.1.266`, or, under the desktop
/// app's managed copies, `.../claude-code/2.1.266/claude.app/...`), so
/// `proc_name` or a raw last-path-component fallback can surface the version
/// string itself instead of a readable name.  This is deliberately narrower
/// than "any process named claude": the Claude and Claude Code desktop apps
/// are regular, Dock-visible applications with their own bundle ids, and are
/// already named and grouped correctly through that path.
enum ClaudeProcess {
    static func isCLI(path: String) -> Bool {
        path.contains("/.local/share/claude/versions/") || path.contains("/claude-code/")
    }

    static let displayName = "Claude Code"
}

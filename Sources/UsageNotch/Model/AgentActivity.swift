import Foundation
import SwiftUI

/// Which CLI a live session belongs to.
enum AgentKind: String {
    case claude, codex

    var label: String { self == .claude ? "Claude Code" : "Codex" }
    var glyph: String { self == .claude ? "CC" : "CX" }
    var tint: Color {
        self == .claude
            ? Color(red: 0.85, green: 0.53, blue: 0.35)
            : Color(red: 0.44, green: 0.72, blue: 0.98)
    }
}

/// A coding session that is currently open, and what it is doing right now.
///
/// This is the notch's equivalent of a Live Activity: the point is not history but
/// "is the agent still working, and on what", visible without switching windows.
struct AgentSession: Identifiable, Equatable {
    var id: String              // transcript path — stable for the life of the session
    var kind: AgentKind
    var project: String
    /// Working directory recorded by the CLI. This is the bridge from an agent turn
    /// to local developer context such as Git state.
    var workspacePath: String? = nil
    var branch: String?
    /// What it is doing: a tool name, "thinking", "responding", or "done".
    var detail: String
    var startedAt: Date
    var lastActivity: Date
    /// False once the agent has finished its turn and handed control back.
    var isWorking: Bool

    var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    static func == (a: AgentSession, b: AgentSession) -> Bool {
        a.id == b.id && a.detail == b.detail && a.isWorking == b.isWorking
            && a.lastActivity == b.lastActivity && a.project == b.project
            && a.workspacePath == b.workspacePath && a.branch == b.branch
    }
}

extension Array where Element == AgentSession {
    /// Working sessions first, then most recently active.
    var ranked: [AgentSession] {
        sorted { lhs, rhs in
            if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    var anyWorking: Bool { contains(where: \.isWorking) }
}

extension Fmt {
    /// Compact elapsed time for a running session: "4m", "1h 12m".
    static func elapsed(_ interval: TimeInterval) -> String {
        let secs = max(Int(interval), 0)
        if secs < 60 { return "\(secs)s" }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }
}

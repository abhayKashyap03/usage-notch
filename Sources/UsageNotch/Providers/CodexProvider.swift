import Foundation
import SwiftUI

/// Reads `~/.codex/sessions/**/rollout-*.jsonl`.
///
/// Unlike Claude Code, Codex records the server's own rate-limit response in every
/// `token_count` event, so these numbers are reported rather than estimated:
///   payload.rate_limits.primary   -> 5-hour window   (window_minutes 300)
///   payload.rate_limits.secondary -> weekly window   (window_minutes 10080)
final class CodexProvider: UsageProvider, @unchecked Sendable {
    let id = "codex"
    private let root = NSHomeDirectory() + "/.codex/sessions"
    private static let tailBytes = 768 * 1024

    func fetch(now: Date) -> ProviderUsage {
        var usage = ProviderUsage(
            id: id, name: "Codex", glyph: "CX",
            tint: Color(red: 0.44, green: 0.72, blue: 0.98),
            session: UsageWindow(fraction: nil, resetsAt: nil, label: "5h", estimated: false),
            week: UsageWindow(fraction: nil, resetsAt: nil, label: "7d", estimated: false),
            tokens: 0, costUSD: nil, plan: nil, lastActivity: nil, status: .idle
        )

        guard FileManager.default.fileExists(atPath: root) else {
            usage.status = .missing
            usage.footnote = "~/.codex/sessions not found"
            return usage
        }

        // Rate limits are per-account, not per-session: the most recent event wins,
        // so walk the newest handful of rollouts until one yields limits.
        let recent = FS.files(under: root, ext: "jsonl")
            .sorted { $0.modified > $1.modified }
            .prefix(4)

        for file in recent {
            guard let reading = Self.lastReading(in: file.path) else { continue }
            usage.tokens = reading.totalTokens
            usage.lastActivity = reading.stamp ?? file.modified
            usage.plan = reading.plan
            if let primary = reading.primary {
                usage.session.fraction = primary.percent / 100
                usage.session.resetsAt = primary.resetsAt
                usage.session.label = Self.label(minutes: primary.windowMinutes, fallback: "5h")
            }
            if let secondary = reading.secondary {
                usage.week.fraction = secondary.percent / 100
                usage.week.resetsAt = secondary.resetsAt
                usage.week.label = Self.label(minutes: secondary.windowMinutes, fallback: "7d")
            }
            usage.status = usage.session.fraction == nil ? .idle : .ok
            if usage.session.fraction == nil {
                usage.footnote = "No rate-limit data in latest session"
            } else if let stamp = usage.lastActivity, now.timeIntervalSince(stamp) > 300 {
                // These numbers come from Codex's own last server response, so they are
                // only as fresh as your last Codex turn — usage from other surfaces
                // (the ChatGPT app, another machine) is not reflected until then.
                usage.footnote = "as of \(Fmt.clock(stamp)) · \(Self.ago(from: stamp, to: now)) old"
            }
            return usage
        }

        usage.footnote = "No recent Codex sessions"
        return usage
    }

    // MARK: - Tail parsing

    private struct Limit {
        let percent: Double
        let windowMinutes: Int?
        let resetsAt: Date?
    }

    private struct Reading {
        var totalTokens: Int = 0
        var primary: Limit?
        var secondary: Limit?
        var plan: String?
        var stamp: Date?
    }

    /// Rollouts are large; only the tail is read, then scanned backwards for the
    /// most recent `token_count` event.
    private static func lastReading(in path: String) -> Reading? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"token_count\"") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count"
            else { continue }

            var reading = Reading()
            reading.stamp = (obj["timestamp"] as? String).flatMap(ISO8601.parse)
            if let info = payload["info"] as? [String: Any],
               let total = info["total_token_usage"] as? [String: Any] {
                reading.totalTokens = total["total_tokens"] as? Int ?? 0
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                reading.plan = limits["plan_type"] as? String
                reading.primary = parse(limits["primary"])
                reading.secondary = parse(limits["secondary"])
            }
            // A token_count without limits is normal early in a session; keep looking.
            if reading.primary != nil || reading.totalTokens > 0 { return reading }
        }
        return nil
    }

    private static func parse(_ raw: Any?) -> Limit? {
        guard let d = raw as? [String: Any], let used = d["used_percent"] as? Double else { return nil }
        let resets = (d["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return Limit(percent: used, windowMinutes: d["window_minutes"] as? Int, resetsAt: resets)
    }

    private static func label(minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func ago(from: Date, to: Date) -> String {
        let mins = Int(to.timeIntervalSince(from) / 60)
        if mins >= 1440 { return "\(mins / 1440)d" }
        if mins >= 60 { return "\(mins / 60)h" }
        return "\(max(mins, 1))m"
    }
}

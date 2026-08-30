import Foundation
import SwiftUI

/// Reads `~/.claude/projects/**/*.jsonl` and reconstructs Claude Code usage.
///
/// Claude Code does not write plan utilisation to disk, so the session ring is a
/// local estimate: assistant messages are bucketed into rolling 5-hour blocks
/// (the same shape as Anthropic's session window) and compared against a ceiling.
/// The ceiling is either user-supplied or "auto" — the busiest block on record.
final class ClaudeCodeProvider: UsageProvider, @unchecked Sendable {
    let id = "claude-code"
    private let root = NSHomeDirectory() + "/.claude/projects"
    private let tail = JSONLTail()
    private var entries: [UsageEntry] = []
    private var seen: Set<String> = []
    private var loadedCache = false
    private var dirty = false

    /// Cheap byte tests that reject the ~99% of transcript lines carrying no usage.
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)
    /// Shared so the menu can probe it directly when the option is switched on.
    let account = AnthropicAccountProvider()

    private static let blockDuration: TimeInterval = 5 * 3600
    private static let retention: TimeInterval = 32 * 24 * 3600

    struct UsageEntry {
        let timestamp: Date
        let model: String
        let input: Int
        let output: Int
        let cacheWrite: Int
        let cacheRead: Int
        let cost: Double
        var total: Int { input + output + cacheWrite + cacheRead }
    }

    private struct Block {
        var start: Date
        var end: Date
        var lastActivity: Date
        var tokens: Int = 0
        var cost: Double = 0
    }

    func fetch(now: Date) -> ProviderUsage {
        var usage = ProviderUsage(
            id: id, name: "Claude Code", glyph: "CC",
            tint: Color(red: 0.85, green: 0.53, blue: 0.35),
            session: UsageWindow(fraction: nil, resetsAt: nil, label: "5h", estimated: true),
            week: UsageWindow(fraction: nil, resetsAt: nil, label: "7d", estimated: true),
            tokens: 0, costUSD: nil, plan: nil, lastActivity: nil, status: .idle
        )

        guard FileManager.default.fileExists(atPath: root) else {
            usage.status = .missing
            usage.footnote = "~/.claude/projects not found"
            return usage
        }

        ingest(now: now)
        guard !entries.isEmpty else {
            usage.footnote = "No sessions in the last 30 days"
            return usage
        }

        let blocks = buildBlocks()
        let metric = Settings.shared.claudeMetric
        func value(_ b: Block) -> Double { metric == .cost ? b.cost : Double(b.tokens) }

        let active = blocks.last.flatMap { b -> Block? in
            let live = now < b.end && now.timeIntervalSince(b.lastActivity) < Self.blockDuration
            return live ? b : nil
        }

        // Auto ceilings: the heaviest block, and the heaviest rolling week, ever seen.
        let historicalPeak = blocks.map(value).max() ?? 0
        var sessionLimit = Settings.shared.claudeSessionLimit
        if sessionLimit <= 0 { sessionLimit = historicalPeak }

        let weekWindow = now.addingTimeInterval(-7 * 24 * 3600)
        let weekEntries = entries.filter { $0.timestamp >= weekWindow }
        let weekTokens = weekEntries.reduce(0) { $0 + $1.total }
        let weekCost = weekEntries.reduce(0.0) { $0 + $1.cost }
        let weekValue = metric == .cost ? weekCost : Double(weekTokens)

        var weeklyLimit = Settings.shared.claudeWeeklyLimit
        if weeklyLimit <= 0 { weeklyLimit = max(peakRollingWeek(metric: metric), weekValue) }

        if let active {
            usage.tokens = active.tokens
            usage.costUSD = active.cost
            usage.lastActivity = active.lastActivity
            usage.session.resetsAt = active.end
            usage.session.fraction = sessionLimit > 0
                ? min(value(active) / sessionLimit, 1.4)
                : nil
            usage.status = .ok
        } else {
            usage.lastActivity = entries.last?.timestamp
            usage.session.fraction = 0
            usage.footnote = "Idle — no active 5h block"
            usage.status = .idle
        }

        usage.week.fraction = weeklyLimit > 0 ? min(weekValue / weeklyLimit, 1.4) : nil
        usage.week.resetsAt = nil

        // Real plan utilisation wins over the estimate when the user opts in.
        if Settings.shared.useAnthropicAccount, let real = account.utilisation() {
            if let five = real.session {
                usage.session.fraction = five.fraction
                usage.session.resetsAt = five.resetsAt
                usage.session.estimated = false
            }
            if let seven = real.week {
                usage.week.fraction = seven.fraction
                usage.week.resetsAt = seven.resetsAt
                usage.week.estimated = false
            }
            usage.plan = real.plan
            usage.status = .ok
            usageDebug("claude: account limits applied (5h=\(usage.session.percent.map(String.init) ?? "–")%)")
        }

        return usage
    }

    // MARK: - Parsing

    private func ingest(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        loadCacheIfNeeded(cutoff: cutoff)
        let files = FS.files(under: root, ext: "jsonl", newerThan: cutoff)
        tail.forget(pathsNotIn: Set(files.map(\.path)))

        for file in files {
            tail.newLines(at: file.path) { data in
                guard data.range(of: Self.usageMarker) != nil,
                      data.range(of: Self.assistantMarker) != nil else { return }
                guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any],
                      let stamp = obj["timestamp"] as? String,
                      let date = ISO8601.parse(stamp)
                else { return }

                // Streaming writes the same assistant turn more than once; the
                // message id plus request id identifies a billable turn exactly.
                let key = "\(message["id"] as? String ?? "-"):\(obj["requestId"] as? String ?? "-")"
                guard !key.hasSuffix(":-"), self.seen.insert(key).inserted else { return }

                let model = message["model"] as? String ?? "unknown"
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                guard input + output + cacheWrite + cacheRead > 0 else { return }

                self.entries.append(UsageEntry(
                    timestamp: date, model: model,
                    input: input, output: output,
                    cacheWrite: cacheWrite, cacheRead: cacheRead,
                    cost: Pricing.cost(model: model, input: input, output: output,
                                       cacheWrite: cacheWrite, cacheRead: cacheRead)
                ))
                self.dirty = true
            }
        }

        let before = entries.count
        entries.removeAll { $0.timestamp < cutoff }
        entries.sort { $0.timestamp < $1.timestamp }
        if entries.count != before { dirty = true }
        if seen.count > 200_000 { seen.removeAll(keepingCapacity: true) }
        saveCacheIfNeeded()
    }

    private func loadCacheIfNeeded(cutoff: Date) {
        guard !loadedCache else { return }
        loadedCache = true
        guard let cache = ClaudeCache.load() else { return }
        tail.savedCursors = cache.cursors
        seen = Set(cache.seen)
        entries = cache.entries
            .filter { Date(timeIntervalSince1970: $0.t) >= cutoff }
            .map {
                UsageEntry(timestamp: Date(timeIntervalSince1970: $0.t), model: $0.m,
                           input: $0.i, output: $0.o, cacheWrite: $0.w, cacheRead: $0.r, cost: $0.c)
            }
        usageDebug("claude: cache restored \(entries.count) entries")
    }

    private func saveCacheIfNeeded() {
        guard dirty else { return }
        dirty = false
        var cache = ClaudeCache()
        cache.cursors = tail.savedCursors
        cache.entries = entries.map {
            ClaudeCache.Entry(t: $0.timestamp.timeIntervalSince1970, m: $0.model,
                              i: $0.input, o: $0.output, w: $0.cacheWrite, r: $0.cacheRead, c: $0.cost)
        }
        // Keys for turns already counted; bounded by the retention window.
        cache.seen = Array(seen.prefix(50_000))
        cache.save()
    }

    /// Groups entries into 5-hour blocks anchored to the top of the hour, starting a
    /// fresh block after a 5-hour gap — the behaviour Anthropic's session window has.
    private func buildBlocks() -> [Block] {
        var blocks: [Block] = []
        var current: Block?

        for e in entries {
            if var b = current,
               e.timestamp.timeIntervalSince(b.start) < Self.blockDuration,
               e.timestamp.timeIntervalSince(b.lastActivity) < Self.blockDuration {
                b.tokens += e.total
                b.cost += e.cost
                b.lastActivity = e.timestamp
                current = b
            } else {
                if let b = current { blocks.append(b) }
                // Truncate to the top of the hour. `date(bySetting:)` would roll
                // *forward* to the next matching hour, which puts the block in the future.
                let cal = Calendar.current
                let start = cal.date(from: cal.dateComponents([.year, .month, .day, .hour], from: e.timestamp))
                    ?? e.timestamp
                var b = Block(start: start,
                              end: start.addingTimeInterval(Self.blockDuration),
                              lastActivity: e.timestamp)
                b.tokens = e.total
                b.cost = e.cost
                current = b
            }
        }
        if let b = current { blocks.append(b) }
        return blocks
    }

    /// Heaviest 7-day rolling total in the retained history, used as the auto weekly ceiling.
    private func peakRollingWeek(metric: ClaudeMetric) -> Double {
        guard !entries.isEmpty else { return 0 }
        var daily: [Date: Double] = [:]
        let cal = Calendar.current
        for e in entries {
            let day = cal.startOfDay(for: e.timestamp)
            daily[day, default: 0] += metric == .cost ? e.cost : Double(e.total)
        }
        let days = daily.keys.sorted()
        var peak = 0.0
        for anchor in days {
            let from = anchor.addingTimeInterval(-6 * 24 * 3600)
            let sum = daily.reduce(0.0) { acc, kv in
                (kv.key >= from && kv.key <= anchor) ? acc + kv.value : acc
            }
            peak = max(peak, sum)
        }
        return peak
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String) -> Date? {
        withFraction.date(from: s) ?? plain.date(from: s)
    }
}

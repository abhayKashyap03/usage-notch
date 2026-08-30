import Foundation

/// Works out which Claude Code and Codex sessions are open right now, and what each
/// one is doing, by reading the tail of the transcript each CLI is already writing.
///
/// Both formats end up in the same place: the last meaningful record says whether the
/// agent is running a tool, thinking, or has handed control back to you.
final class AgentActivityProvider: @unchecked Sendable {
    private let claudeRoot = NSHomeDirectory() + "/.claude/projects"
    private let codexRoot = NSHomeDirectory() + "/.codex/sessions"

    /// Transcripts untouched for longer than this are not live sessions any more.
    private static let liveWindow: TimeInterval = 20 * 60
    /// After this much silence the agent is waiting on you rather than working.
    private static let idleAfter: TimeInterval = 75
    private static let tailBytes = 96 * 1024
    private static let maxSessions = 4

    /// Session start and project name never change, so they are read once per file.
    private var headCache: [String: (started: Date, project: String)] = [:]
    private let lock = NSLock()

    func sessions(now: Date = Date()) -> [AgentSession] {
        let cutoff = now.addingTimeInterval(-Self.liveWindow)
        var out: [AgentSession] = []
        for file in FS.files(under: claudeRoot, ext: "jsonl", newerThan: cutoff) {
            if let session = claudeSession(path: file.path, modified: file.modified, now: now) {
                out.append(session)
            }
        }
        for file in FS.files(under: codexRoot, ext: "jsonl", newerThan: cutoff) {
            if let session = codexSession(path: file.path, modified: file.modified, now: now) {
                out.append(session)
            }
        }
        // More than a handful of rows stops being glanceable, which is the point.
        return Array(out.ranked.prefix(Self.maxSessions))
    }

    // MARK: - Claude Code

    private func claudeSession(path: String, modified: Date, now: Date) -> AgentSession? {
        guard let lines = Self.tailLines(of: path) else { return nil }

        var detail: String?
        var stamp: Date?
        var branch: String?
        var cwd: String?

        // Walk backwards to the newest record that says something about state.
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String
            else { continue }
            if cwd == nil { cwd = obj["cwd"] as? String }
            if branch == nil { branch = obj["gitBranch"] as? String }

            let message = obj["message"] as? [String: Any]
            let content = message?["content"] as? [[String: Any]] ?? []

            switch type {
            case "assistant":
                // A tool_use block is the most informative thing in the file.
                if let tool = content.compactMap({ $0["name"] as? String }).last {
                    detail = tool
                } else if content.contains(where: { ($0["type"] as? String) == "thinking" }) {
                    detail = "thinking"
                } else {
                    detail = "responding"
                }
            case "user":
                let isToolResult = content.contains { ($0["type"] as? String) == "tool_result" }
                detail = isToolResult ? "thinking" : "starting"
            default:
                continue    // attachments, summaries, hooks
            }
            stamp = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? modified
            break
        }

        guard let detail, let stamp else { return nil }
        let head = claudeHead(path: path, fallbackProject: cwd, fallbackDate: stamp)
        let working = now.timeIntervalSince(stamp) < Self.idleAfter

        return AgentSession(
            id: path, kind: .claude,
            project: head.project,
            branch: branch == "HEAD" ? nil : branch,
            detail: working ? detail : "waiting for you",
            startedAt: head.started, lastActivity: stamp, isWorking: working
        )
    }

    private func claudeHead(path: String, fallbackProject: String?, fallbackDate: Date) -> (started: Date, project: String) {
        lock.lock()
        if let cached = headCache[path] { lock.unlock(); return cached }
        lock.unlock()

        var started = fallbackDate
        var project = (fallbackProject as NSString?)?.lastPathComponent
            ?? (path as NSString).deletingLastPathComponent.components(separatedBy: "-").last
            ?? "session"

        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 64 * 1024) {
                var foundStart = false
                // The first records are often summaries or attachments with no
                // timestamp, so keep going until one carries the fields we need.
                for line in head.split(separator: UInt8(ascii: "\n")) {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                    else { continue }
                    if !foundStart, let stamp = (obj["timestamp"] as? String).flatMap(ISO8601.parse) {
                        started = stamp
                        foundStart = true
                    }
                    if let cwd = obj["cwd"] as? String { project = (cwd as NSString).lastPathComponent }
                    if foundStart && project != "session" { break }
                }
            }
        }

        let value = (started, project)
        lock.lock(); headCache[path] = value; lock.unlock()
        return value
    }

    // MARK: - Codex

    private func codexSession(path: String, modified: Date, now: Date) -> AgentSession? {
        guard let lines = Self.tailLines(of: path) else { return nil }

        var detail: String?
        var stamp: Date?
        for line in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let kind = payload["type"] as? String
            else { continue }

            switch kind {
            case "agent_reasoning", "reasoning", "agent_reasoning_delta":
                detail = "thinking"
            case "exec_command_begin":
                detail = Self.commandName(payload["command"]) ?? "running command"
            case "exec_command_end", "custom_tool_call_output", "patch_apply_end":
                detail = "thinking"
            case "custom_tool_call", "function_call":
                detail = (payload["name"] as? String) ?? "running tool"
            case "patch_apply_begin":
                detail = "editing"
            case "agent_message", "output_text":
                detail = "responding"
            default:
                continue    // token_count, world_state, session_meta and friends
            }
            stamp = (obj["timestamp"] as? String).flatMap(ISO8601.parse) ?? modified
            break
        }

        guard let detail, let stamp else { return nil }
        let head = codexHead(path: path, fallbackDate: stamp)
        let working = now.timeIntervalSince(stamp) < Self.idleAfter

        return AgentSession(
            id: path, kind: .codex,
            project: head.project, branch: nil,
            detail: working ? detail : "waiting for you",
            startedAt: head.started, lastActivity: stamp, isWorking: working
        )
    }

    private func codexHead(path: String, fallbackDate: Date) -> (started: Date, project: String) {
        lock.lock()
        if let cached = headCache[path] { lock.unlock(); return cached }
        lock.unlock()

        var started = fallbackDate
        var project = "codex"
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let head = try? handle.read(upToCount: 64 * 1024),
               let text = String(data: head, encoding: .utf8) {
                // The rollout header carries the working directory in its world state.
                if let range = text.range(of: "\"cwd\":\"") {
                    let rest = text[range.upperBound...]
                    if let end = rest.firstIndex(of: "\"") {
                        project = (String(rest[..<end]) as NSString).lastPathComponent
                    }
                }
                for line in text.split(separator: "\n") {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let stamp = (obj["timestamp"] as? String).flatMap(ISO8601.parse) else { continue }
                    started = stamp
                    break
                }
            }
        }

        let value = (started, project)
        lock.lock(); headCache[path] = value; lock.unlock()
        return value
    }

    // MARK: - Shared

    private static func tailLines(of path: String) -> [Data]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let newline = UInt8(ascii: "\n")
        var lines: [Data] = []
        var start = data.startIndex
        while let nl = data[start...].firstIndex(of: newline) {
            if nl > start { lines.append(Data(data[start..<nl])) }
            start = data.index(after: nl)
        }
        if start < data.endIndex { lines.append(Data(data[start...])) }
        return lines
    }

    private static func commandName(_ raw: Any?) -> String? {
        if let list = raw as? [String] {
            // ["bash", "-lc", "swift build"] reads better as "swift build".
            let meaningful = list.drop { $0 == "bash" || $0 == "zsh" || $0.hasPrefix("-") }
            return meaningful.first.map { ($0 as NSString).lastPathComponent }
        }
        if let text = raw as? String { return text.components(separatedBy: " ").first }
        return nil
    }
}

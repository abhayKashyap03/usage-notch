import Foundation

/// Reads the Git state for workspaces with a live agent session.
///
/// Git is invoked read-only with optional locks disabled. Commands have a short
/// deadline so a broken repository, filesystem mount, or hook cannot stall the UI.
final class DeveloperContextProvider: @unchecked Sendable {
    private static let commandDeadline: TimeInterval = 1.5
    private static let maxOutputBytes = 512 * 1024

    func workspaces(for sessions: [AgentSession], now: Date = Date()) -> [WorkspaceState] {
        var seen = Set<String>()
        var states: [WorkspaceState] = []

        for session in sessions.ranked {
            guard let path = session.workspacePath,
                  FileManager.default.fileExists(atPath: path),
                  let root = git(["-C", path, "rev-parse", "--show-toplevel"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !root.isEmpty,
                  seen.insert(root).inserted,
                  let status = git(["-C", root, "status", "--porcelain=v1", "--branch"])
            else { continue }

            let parsed = Self.parseStatus(status, fallbackBranch: session.branch)
            states.append(WorkspaceState(
                project: (root as NSString).lastPathComponent,
                rootPath: root,
                branch: parsed.branch,
                changedFiles: parsed.changedFiles,
                ahead: parsed.ahead,
                behind: parsed.behind,
                checkedAt: now
            ))
        }

        return states
    }

    static func parseStatus(
        _ output: String,
        fallbackBranch: String? = nil
    ) -> (branch: String, changedFiles: Int, ahead: Int, behind: Int) {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let first = lines.first, first.hasPrefix("## ") else {
            return (fallbackBranch ?? "detached", lines.count, 0, 0)
        }

        let header = String(first.dropFirst(3))
        let branch: String
        if header.hasPrefix("No commits yet on ") {
            branch = String(header.dropFirst("No commits yet on ".count))
        } else if header.hasPrefix("Initial commit on ") {
            branch = String(header.dropFirst("Initial commit on ".count))
        } else if header.hasPrefix("HEAD (no branch)") {
            branch = fallbackBranch ?? "detached"
        } else {
            branch = header.components(separatedBy: "...").first?
                .components(separatedBy: " ").first ?? fallbackBranch ?? "detached"
        }

        let words = header
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: ",", with: "")
            .split(separator: " ")
            .map(String.init)
        func count(after marker: String) -> Int {
            guard let index = words.firstIndex(of: marker), words.indices.contains(index + 1) else { return 0 }
            return Int(words[index + 1]) ?? 0
        }

        return (branch, max(lines.count - 1, 0), count(after: "ahead"), count(after: "behind"))
    }

    private func git(_ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        let buffer = CommandOutput(limit: Self.maxOutputBytes)
        let finished = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.fsmonitor=false"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_OPTIONAL_LOCKS": "0",
            "LC_ALL": "C",
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { buffer.append(data) }
        }

        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        if finished.wait(timeout: .now() + Self.commandDeadline) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 0.25)
            output.fileHandleForReading.readabilityHandler = nil
            return nil
        }

        output.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        guard process.terminationStatus == 0, !buffer.wasTruncated else { return nil }
        return String(data: buffer.data, encoding: .utf8)
    }
}

private final class CommandOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var truncated = false

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let available = max(limit - storage.count, 0)
        if data.count > available { truncated = true }
        guard available > 0 else { return }
        storage.append(data.prefix(available))
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var wasTruncated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return truncated
    }
}

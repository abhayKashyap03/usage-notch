import Foundation

/// Keeps the vendors' own credentials fresh by asking their own CLIs to do it.
///
/// Neither `claude auth status` nor `codex login status` renews anything — they
/// only read local state. A token is refreshed when the CLI actually makes an
/// authenticated request, so that is what this does: the smallest possible request,
/// on the cheapest model, only when the data has gone stale.
///
/// The alternative was to perform the OAuth refresh ourselves using the stored
/// refresh token, which means presenting the CLI's client identity to the vendor's
/// token endpoint. Driving the official CLI avoids impersonating anything.
enum CLIRefresher {
    /// A ping costs a handful of tokens, so never more often than this.
    private static let minimumInterval: TimeInterval = 15 * 60

    private static let lock = NSLock()
    private static var lastRun: [String: Date] = [:]

    /// GUI apps do not inherit a login shell's PATH.
    private static let searchPaths = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
        NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.claude/local",
    ]

    static func locate(_ tool: String) -> String? {
        for directory in searchPaths {
            let path = directory + "/" + tool
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    @discardableResult
    static func refreshClaude() -> Bool {
        run(tool: "claude",
            arguments: ["-p", "--model", "claude-haiku-4-5-20251001", "ok"],
            key: "claude")
    }

    /// Codex publishes its rate limits only in a session transcript, so the ping both
    /// refreshes the token and produces a current reading.
    @discardableResult
    static func refreshCodex() -> Bool {
        run(tool: "codex", arguments: ["exec", "--skip-git-repo-check", "ok"], key: "codex")
    }

    private static func run(tool: String, arguments: [String], key: String) -> Bool {
        lock.lock()
        let recent = lastRun[key].map { Date().timeIntervalSince($0) < minimumInterval } ?? false
        if !recent { lastRun[key] = Date() }
        lock.unlock()
        guard !recent, let executable = locate(tool) else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // A GUI app's environment is minimal; the CLIs need a usable PATH and HOME.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        environment["HOME"] = NSHomeDirectory()
        process.environment = environment

        do {
            try process.run()
        } catch {
            usageDebug("refresher: could not run \(tool): \(error.localizedDescription)")
            return false
        }

        // Do not let a hung CLI linger.
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        usageDebug("refresher: \(tool) ping exited \(process.terminationStatus)")
        return process.terminationStatus == 0
    }
}

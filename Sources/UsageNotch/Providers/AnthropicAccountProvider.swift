import Foundation
import Security
import AppKit

/// Optional, opt-in source of *real* Claude plan utilisation.
///
/// Claude Code stores its OAuth token in the login keychain; with the user's
/// consent we reuse it to ask Anthropic how much of the 5-hour and weekly windows
/// is spent, which beats the local estimate.
///
/// Reading that item can put up a keychain authorisation prompt, and an accessory
/// app cannot reliably surface one — so this never runs on the path that feeds the
/// pill. Callers get the last cached answer immediately while a refresh happens on
/// a private queue; the very first read is done explicitly, with the app activated,
/// when the user turns the option on.
final class AnthropicAccountProvider: @unchecked Sendable {
    struct Result {
        var session: UsageWindow?
        var week: UsageWindow?
        var plan: String?
    }

    private static let service = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let refreshInterval: TimeInterval = 120

    private let queue = DispatchQueue(label: "com.abhaykashyap.usagenotch.account", qos: .utility)
    private let lock = NSLock()
    private var cached: Result?
    private var lastAttempt: Date = .distantPast
    private var inFlight = false
    /// True once a read has actually worked. Until then we do not retry in the
    /// background: the keychain can block on an authorisation prompt, and an
    /// accessory app cannot reliably show one.
    private var everSucceeded = false
    /// Set when a read gave up, so the panel can say the estimate is a fallback.
    private(set) var lastFailure: String?

    /// Fired on the main queue when a background load lands, so the UI can pick the
    /// real numbers up immediately instead of waiting for the next refresh tick.
    var onUpdate: (() -> Void)?

    /// Never blocks. Returns the last known answer and schedules a refresh if stale.
    func utilisation(now: Date = Date()) -> Result? {
        lock.lock()
        let result = cached
        // Only poll on a schedule once we know the read works unattended.
        let due = !inFlight && everSucceeded && now.timeIntervalSince(lastAttempt) > Self.refreshInterval
        if due { inFlight = true }
        lock.unlock()

        if due {
            queue.async { [weak self] in
                guard let self else { return }
                let fresh = self.loadWithTimeout()
                self.lock.lock()
                if fresh != nil { self.cached = fresh; self.everSucceeded = true }
                self.lastAttempt = Date()
                self.inFlight = false
                self.lock.unlock()
                usageDebug("account: refreshed (\(fresh == nil ? "no data" : "ok"))")
                if fresh != nil { DispatchQueue.main.async { self.onUpdate?() } }
            }
        }
        return result
    }

    /// Explicit first read, used when the user enables the option. The app is
    /// activated first so any keychain prompt lands in front of them.
    func probe(completion: @escaping (Bool) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.loadWithTimeout(seconds: 30)   // a prompt needs answering
            self.lock.lock()
            self.cached = result
            if result != nil { self.everSucceeded = true }
            self.lastAttempt = Date()
            self.lock.unlock()
            DispatchQueue.main.async { completion(result != nil) }
        }
    }

    /// Diagnostic path: read once, right now, and say what happened.
    func probeBlocking(seconds: TimeInterval = 12) -> Result? {
        let result = loadWithTimeout(seconds: seconds)
        lock.lock()
        if result != nil { cached = result; everSucceeded = true }
        lastAttempt = Date()
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        cached = nil
        lastAttempt = .distantPast
        lock.unlock()
    }

    /// Reads with a deadline. `SecItemCopyMatching` blocks indefinitely while an
    /// authorisation prompt is unanswered, which would otherwise wedge the refresh.
    private func loadWithTimeout(seconds: TimeInterval = 5) -> Result? {
        let done = DispatchSemaphore(value: 0)
        var result: Result?
        DispatchQueue.global(qos: .utility).async {
            result = self.load()
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            lock.lock(); lastFailure = "keychain access is waiting for approval"; lock.unlock()
            usageDebug("account: timed out (likely an unanswered keychain prompt)")
            return nil
        }
        lock.lock(); lastFailure = result == nil ? "Anthropic returned no usable data" : nil; lock.unlock()
        return result
    }

    private func load() -> Result? {
        guard let token = keychainToken() else {
            usageDebug("account: no usable token in the keychain")
            return nil
        }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if (200..<300).contains(status) {
                payload = data
            } else {
                // Keys and status only: never the token, never the body verbatim.
                usageDebug("account: HTTP \(status) \(error.map { "error: \($0.localizedDescription)" } ?? "")")
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)

        guard let payload,
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        let decoded = Self.decode(root)
        if decoded == nil { usageDebug("account: unrecognised response shape, keys=\(root.keys.sorted())") }
        return decoded
    }

    /// The response shape has moved around across Claude Code releases, so match on
    /// the field names rather than a fixed path.
    static func decode(_ root: [String: Any]) -> Result? {
        var result = Result()
        result.plan = (root["subscription_type"] as? String) ?? (root["plan"] as? String)

        func window(_ any: Any?, label: String) -> UsageWindow? {
            guard let d = any as? [String: Any] else { return nil }
            let raw = (d["utilization"] as? Double)
                ?? (d["used_percent"] as? Double)
                ?? (d["percent_used"] as? Double)
            guard let raw else { return nil }
            let fraction = raw > 1.001 ? raw / 100 : raw
            var resets: Date?
            if let epoch = d["resets_at"] as? Double { resets = Date(timeIntervalSince1970: epoch) }
            if let iso = d["resets_at"] as? String { resets = ISO8601.parse(iso) }
            let length: TimeInterval = label == "5h" ? 5 * 3600 : 7 * 24 * 3600
            return UsageWindow(fraction: min(fraction, 1.4), resetsAt: resets, label: label, length: length, estimated: false)
        }

        for (key, value) in root {
            switch key {
            case "five_hour", "5h", "session":
                result.session = window(value, label: "5h")
            case "seven_day", "week", "weekly":
                result.week = window(value, label: "7d")
            case "seven_day_opus", "weekly_opus":
                if result.week == nil { result.week = window(value, label: "7d") }
            default:
                continue
            }
        }
        return (result.session == nil && result.week == nil) ? nil : result
    }

    /// Reads the Claude Code credential blob and keeps only the access token.
    ///
    /// There is rarely just one: Claude Code stores a credential per installation
    /// (`Claude Code-credentials`, plus suffixed variants), and the plain-named one is
    /// often the stalest. Every matching item is considered and the freshest unexpired
    /// token wins.
    private func keychainToken() -> String? {
        // Two steps on purpose: asking for every item *and* its data at once is
        // rejected with errSecParam (-50), so list the services first, then fetch
        // each blob individually.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(listQuery as CFDictionary, &items)
        guard status == errSecSuccess, let entries = items as? [[String: Any]] else {
            usageDebug("account: keychain listing failed with OSStatus \(status)")
            return nil
        }

        // Exact name first, then the per-installation variants. Reading an item the
        // app has not been granted raises a keychain prompt, so stop at the first
        // valid token rather than walking the whole list.
        let services = Set(entries.compactMap { $0[kSecAttrService as String] as? String })
            .filter { $0.hasPrefix(Self.service) }
            .sorted { lhs, _ in lhs == Self.service }
            // Suffixed items are per-plugin MCP tokens, not Claude credentials, and
            // reading each one raises its own keychain prompt. Try a couple, no more.
            .prefix(3)
        guard !services.isEmpty else {
            usageDebug("account: no Claude Code credentials found")
            return nil
        }

        var best: (token: String, expiry: Date)?
        var sawExpired = false
        for service in Array(services) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
            guard let token = oauth["accessToken"] as? String else { continue }
            let expiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                ?? Date.distantFuture
            guard expiry > Date() else { sawExpired = true; continue }
            if best == nil || expiry > best!.expiry { best = (token, expiry) }
            if best != nil { break }
        }

        if best == nil {
            usageDebug(sawExpired
                ? "account: every stored token has expired; Claude Code refreshes them on next use"
                : "account: found credentials but no usable token")
            lock.lock()
            lastFailure = sawExpired ? "Claude Code token expired" : "no usable Claude credentials"
            lock.unlock()
        } else {
            usageDebug("account: using token from \(services.count) candidate credential(s)")
        }
        return best?.token
    }

}

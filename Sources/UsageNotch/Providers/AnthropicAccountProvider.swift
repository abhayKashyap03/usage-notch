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
    /// The usage endpoint rate-limits, so ask rarely: plan utilisation moves slowly
    /// and nothing here is worth a 429.
    private static let refreshInterval: TimeInterval = 300

    private let queue = DispatchQueue(label: "com.abhaykashyap.usagenotch.account", qos: .utility)
    private let lock = NSLock()
    private var cached: Result?
    private var lastAttempt: Date = .distantPast
    private var inFlight = false
    /// Set when a read timed out waiting on a keychain prompt. Backing off then is
    /// right; refusing to try at all — which is what gating on a prior success did —
    /// meant the account path never ran, and the panel silently showed estimates
    /// forever even with a perfectly good token sitting in the keychain.
    private var lastTimeout: Date?
    /// Set when the endpoint asks us to slow down.
    private var backoffUntil: Date?
    private var lastSuccessAt: Date?
    /// Set when a read gave up, so the panel can say the estimate is a fallback.
    private(set) var lastFailure: String?
    /// True when the stored token has lapsed, which a CLI ping can fix.
    private(set) var tokenExpired = false

    /// Fired on the main queue when a background load lands, so the UI can pick the
    /// real numbers up immediately instead of waiting for the next refresh tick.
    var onUpdate: (() -> Void)?

    /// Never blocks. Returns the last known answer and schedules a refresh if stale.
    func utilisation(now: Date = Date()) -> Result? {
        lock.lock()
        let result = cached
        // Back off only after a prompt actually blocked us, not by default.
        let blocked = (lastTimeout.map { now.timeIntervalSince($0) < 120 } ?? false)
            || (backoffUntil.map { now < $0 } ?? false)
        let due = !inFlight && !blocked && now.timeIntervalSince(lastAttempt) > Self.refreshInterval
        if due { inFlight = true }
        lock.unlock()

        if due {
            queue.async { [weak self] in
                guard let self else { return }
                let fresh = self.loadWithTimeout()
                self.lock.lock()
                if fresh != nil {
                    self.cached = fresh
                    self.lastTimeout = nil
                    self.tokenExpired = false
                    self.lastSuccessAt = Date()
                }
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

            self.lastAttempt = Date()
            self.lock.unlock()
            DispatchQueue.main.async { completion(result != nil) }
        }
    }

    /// Diagnostic path: read once, right now, and say what happened.
    /// When the cached answer was fetched, so the panel can admit to showing old data.
    var lastSuccess: Date? {
        lock.lock(); defer { lock.unlock() }
        return cached == nil ? nil : lastSuccessAt
    }

    /// True while the endpoint has told us to wait.
    var isBackingOff: Bool {
        lock.lock(); defer { lock.unlock() }
        return backoffUntil.map { Date() < $0 } ?? false
    }

    func probeBlocking(seconds: TimeInterval = 12) -> Result? {
        let result = loadWithTimeout(seconds: seconds)
        lock.lock()
        if result != nil { cached = result; lastTimeout = nil }
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
    /// 20 seconds, not 5: the read is a keychain lookup *and* a network round trip,
    /// and a deadline tight enough to trip on a slow response was being mistaken for
    /// "a prompt is blocking us" — which parked the background path for ten minutes,
    /// where it timed out and parked again. Toggling the setting was the only way out,
    /// because that path always had thirty seconds.
    private func loadWithTimeout(seconds: TimeInterval = 20) -> Result? {
        let done = DispatchSemaphore(value: 0)
        var result: Result?
        DispatchQueue.global(qos: .utility).async {
            result = self.load()
            done.signal()
        }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            lock.lock()
            lastFailure = "keychain access is waiting for approval"
            lastTimeout = Date()
            lock.unlock()
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
                if status == 429 {
                    // Honour Retry-After when offered; otherwise wait long enough that
                    // repeated launches cannot keep us throttled.
                    let retryAfter = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Retry-After")
                        .flatMap(Double.init) ?? 900
                    self.lock.lock()
                    self.backoffUntil = Date().addingTimeInterval(min(max(retryAfter, 60), 3600))
                    self.lastFailure = "usage endpoint rate-limited"
                    self.lock.unlock()
                }
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
        // Only the exact service holds Claude's own credential. The suffixed
        // `Claude Code-credentials-<hash>` items are per-plugin MCP tokens, and
        // reading them raises a keychain prompt that can never produce an answer.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            usageDebug("account: keychain read failed with OSStatus \(status)")
            lock.lock(); lastFailure = "keychain access not granted"; lock.unlock()
            return nil
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let token = oauth["accessToken"] as? String else {
            usageDebug("account: credential has no access token")
            return nil
        }
        if let expires = oauth["expiresAt"] as? Double {
            let expiry = Date(timeIntervalSince1970: expires / 1000)
            guard expiry > Date() else {
                usageDebug("account: token expired at \(expiry)")
                lock.lock(); lastFailure = "Claude token expired"; tokenExpired = true; lock.unlock()
                return nil
            }
        }
        return token
    }

}

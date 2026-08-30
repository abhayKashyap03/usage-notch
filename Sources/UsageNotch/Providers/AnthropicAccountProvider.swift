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

    /// Fired on the main queue when a background load lands, so the UI can pick the
    /// real numbers up immediately instead of waiting for the next refresh tick.
    var onUpdate: (() -> Void)?

    /// Never blocks. Returns the last known answer and schedules a refresh if stale.
    func utilisation(now: Date = Date()) -> Result? {
        lock.lock()
        let result = cached
        let due = !inFlight && now.timeIntervalSince(lastAttempt) > Self.refreshInterval
        if due { inFlight = true }
        lock.unlock()

        if due {
            queue.async { [weak self] in
                guard let self else { return }
                let fresh = self.load()
                self.lock.lock()
                if fresh != nil { self.cached = fresh }
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
            let result = self.load()
            self.lock.lock()
            self.cached = result
            self.lastAttempt = Date()
            self.lock.unlock()
            DispatchQueue.main.async { completion(result != nil) }
        }
    }

    func reset() {
        lock.lock()
        cached = nil
        lastAttempt = .distantPast
        lock.unlock()
    }

    private func load() -> Result? {
        guard let token = keychainToken() else { return nil }
        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 6
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var payload: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                payload = data
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 8)

        guard let payload,
              let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        return Self.decode(root)
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
            return UsageWindow(fraction: min(fraction, 1.4), resetsAt: resets, label: label, estimated: false)
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
    private func keychainToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let oauth = json["claudeAiOauth"] as? [String: Any] {
            if let expires = oauth["expiresAt"] as? Double,
               Date(timeIntervalSince1970: expires / 1000) < Date() { return nil }
            return oauth["accessToken"] as? String
        }
        return json["accessToken"] as? String
    }
}

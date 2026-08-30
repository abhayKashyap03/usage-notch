import Foundation
import Combine
import SwiftUI

/// Set USAGENOTCH_DEBUG=1 to trace the refresh pipeline on stderr.
func usageDebug(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["USAGENOTCH_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[usage-notch] " + message() + "\n").utf8))
}

/// Owns the providers and the refresh cadence.
///
/// Providers run concurrently and the snapshot is published on a deadline: one slow
/// or wedged source (a keychain prompt, a stalled disk) can no longer freeze the
/// pill — its previous reading is carried forward instead.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot()
    @Published private(set) var isRefreshing = false

    let claude = ClaudeCodeProvider()
    let codex = CodexProvider()

    private let pool = DispatchQueue(label: "com.abhaykashyap.usagenotch.providers",
                                     qos: .utility, attributes: .concurrent)
    private var timer: Timer?
    /// Providers whose previous fetch never returned; they are not launched again.
    private var stalled: Set<String> = []

    private static let deadline: TimeInterval = 6

    func start() {
        refresh()
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: Settings.shared.refreshSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Same work as `refresh()` but inline on the caller. Used by the render harness,
    /// where there is no run loop to deliver an async result.
    func refreshBlocking(now: Date = Date()) {
        var providers: [ProviderUsage] = []
        for provider in active() { providers.append(provider.fetch(now: now)) }
        snapshot = UsageSnapshot(providers: providers, updatedAt: now)
    }

    /// Plausible stand-in readings for the README screenshots.
    func loadDemoData() {
        let now = Date()
        var claude = ProviderUsage(
            id: "claude-code", name: "Claude Code", glyph: "CC",
            tint: Color(red: 0.85, green: 0.53, blue: 0.35),
            session: UsageWindow(fraction: 0.38, resetsAt: now.addingTimeInterval(2 * 3600 + 41 * 60),
                                 label: "5h", estimated: false),
            week: UsageWindow(fraction: 0.21, resetsAt: nil, label: "7d", estimated: false),
            tokens: 4_200_000, costUSD: nil, plan: "max", lastActivity: now, status: .ok
        )
        claude.footnote = nil
        var codex = ProviderUsage(
            id: "codex", name: "Codex", glyph: "CX",
            tint: Color(red: 0.44, green: 0.72, blue: 0.98),
            session: UsageWindow(fraction: 0.72, resetsAt: now.addingTimeInterval(3 * 3600 + 12 * 60),
                                 label: "5h", estimated: false),
            week: UsageWindow(fraction: 0.46, resetsAt: nil, label: "7d", estimated: false),
            tokens: 1_800_000, costUSD: nil, plan: "plus", lastActivity: now, status: .ok
        )
        codex.footnote = nil
        snapshot = UsageSnapshot(providers: [claude, codex], updatedAt: now)
    }

    func refresh() {
        guard !isRefreshing else { return }
        let providers = active().filter { !stalled.contains($0.id) }
        guard !providers.isEmpty else { return }
        isRefreshing = true

        let now = Date()
        let group = DispatchGroup()
        let box = ResultBox()
        let order = providers.map(\.id)

        for provider in providers {
            group.enter()
            pool.async { [weak self] in
                let started = Date()
                let usage = provider.fetch(now: now)
                usageDebug("\(provider.id) fetched in \(Int(Date().timeIntervalSince(started) * 1000))ms")
                box.put(provider.id, usage)
                // Show each source the moment it answers instead of holding the whole
                // panel back for the slowest one.
                DispatchQueue.main.async { self?.merge(usage, order: order, now: now) }
                group.leave()
            }
        }

        pool.async { [weak self] in
            let timedOut = group.wait(timeout: .now() + Self.deadline) == .timedOut
            let results = box.all()
            DispatchQueue.main.async {
                guard let self else { return }
                if timedOut {
                    let missing = order.filter { results[$0] == nil }
                    self.stalled.formUnion(missing)
                    usageDebug("refresh timed out; parked \(missing)")
                }
                self.isRefreshing = false
            }
        }
    }

    /// Slots one provider's fresh reading into the snapshot, keeping the configured
    /// provider order stable.
    private func merge(_ usage: ProviderUsage, order: [String], now: Date) {
        var rows = snapshot.providers.filter { order.contains($0.id) && $0.id != usage.id }
        rows.append(usage)
        rows.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        snapshot = UsageSnapshot(providers: rows, updatedAt: now)
        usageDebug("merged \(usage.id): \(snapshot.visible.count) visible")
    }

    /// Clears the parked list, e.g. after the user changes a setting that caused it.
    func revive() {
        stalled.removeAll()
    }

    private func active() -> [UsageProvider] {
        var list: [UsageProvider] = []
        if Settings.shared.showClaude { list.append(claude) }
        if Settings.shared.showCodex { list.append(codex) }
        return list
    }
}

/// Tiny thread-safe collector for the concurrent fetches.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ProviderUsage] = [:]

    func put(_ id: String, _ usage: ProviderUsage) {
        lock.lock(); values[id] = usage; lock.unlock()
    }

    func all() -> [String: ProviderUsage] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

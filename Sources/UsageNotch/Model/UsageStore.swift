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
    /// Sessions open right now. Refreshed far more often than usage: this is the part
    /// that has to feel live.
    @Published private(set) var sessions: [AgentSession] = []
    /// Read-only local developer context for the workspaces behind those sessions.
    @Published private(set) var workspaces: [WorkspaceState] = []

    let claude = ClaudeCodeProvider()
    let codex = CodexProvider()
    private let activity = AgentActivityProvider()
    private let developerContext = DeveloperContextProvider()

    private let pool = DispatchQueue(label: "com.abhaykashyap.usagenotch.providers",
                                     qos: .utility, attributes: .concurrent)
    private var timer: Timer?
    private var activityTimer: Timer?
    private var activityInterval: TimeInterval = 0
    private var activityBusy = false
    private var workspaceBusy = false
    private var lastWorkspaceRefresh = Date.distantPast
    /// Providers whose previous fetch never returned; they are not launched again.
    private var stalled: Set<String> = []

    private static let deadline: TimeInterval = 6

    func start() {
        refresh()
        scheduleTimer()
        refreshActivity()
    }

    /// Tail the live transcripts. Cheap enough to run every couple of seconds while an
    /// agent is actually working, and backs off when nothing is happening.
    func refreshActivity(forceWorkspace: Bool = false) {
        guard Settings.shared.showAgents else {
            if !sessions.isEmpty { sessions = [] }
            if !workspaces.isEmpty { workspaces = [] }
            scheduleActivityTimer(interval: 8)
            return
        }
        guard !activityBusy else { return }
        activityBusy = true

        pool.async { [weak self, activity] in
            let found = activity.sessions()
            DispatchQueue.main.async {
                guard let self else { return }
                self.activityBusy = false
                if found != self.sessions { self.sessions = found }
                self.refreshWorkspaces(for: found, force: forceWorkspace)
                self.scheduleActivityTimer(interval: found.anyWorking ? 2 : 6)
            }
        }
    }

    /// Git status is heavier than tailing a transcript, so it has its own cadence and
    /// never overlaps with a previous check.
    private func refreshWorkspaces(for sessions: [AgentSession], force: Bool = false) {
        guard Settings.shared.showWorkspaceState else {
            if !workspaces.isEmpty { workspaces = [] }
            return
        }
        guard !sessions.isEmpty else {
            if !workspaces.isEmpty { workspaces = [] }
            return
        }
        guard !workspaceBusy else { return }
        guard force || Date().timeIntervalSince(lastWorkspaceRefresh) >= 6 else { return }

        workspaceBusy = true
        lastWorkspaceRefresh = Date()
        pool.async { [weak self, developerContext] in
            let found = developerContext.workspaces(for: sessions)
            DispatchQueue.main.async {
                guard let self else { return }
                self.workspaceBusy = false
                if found != self.workspaces { self.workspaces = found }
            }
        }
    }

    private func scheduleActivityTimer(interval: TimeInterval) {
        guard interval != activityInterval || activityTimer == nil else { return }
        activityInterval = interval
        activityTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshActivity() }
        }
        t.tolerance = interval / 4
        RunLoop.main.add(t, forMode: .common)
        activityTimer = t
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
        if Settings.shared.showAgents {
            sessions = activity.sessions(now: now)
            if Settings.shared.showWorkspaceState {
                workspaces = developerContext.workspaces(for: sessions, now: now)
            }
        }
    }

    /// Plausible stand-in readings for the README screenshots.
    func loadDemoData(idle: Bool = false) {
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
        sessions = idle ? [] : [
            AgentSession(id: "demo-1", kind: .claude, project: "usage-notch",
                         workspacePath: "/Projects/usage-notch", branch: "main",
                         detail: "Edit", startedAt: now.addingTimeInterval(-14 * 60),
                         lastActivity: now, isWorking: true),
            AgentSession(id: "demo-2", kind: .codex, project: "api-gateway",
                         workspacePath: "/Projects/api-gateway", branch: nil,
                         detail: "waiting for you", startedAt: now.addingTimeInterval(-52 * 60),
                         lastActivity: now.addingTimeInterval(-140), isWorking: false),
        ]
        workspaces = idle ? [] : [
            WorkspaceState(project: "usage-notch", rootPath: "/Projects/usage-notch",
                           branch: "main", changedFiles: 3, ahead: 1, behind: 0, checkedAt: now),
            WorkspaceState(project: "api-gateway", rootPath: "/Projects/api-gateway",
                           branch: "fix/auth", changedFiles: 0, ahead: 0, behind: 2, checkedAt: now),
        ]
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

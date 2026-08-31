import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: NotchState
    var onRefresh: () -> Void
    var onToggleMini: () -> Void
    var onHitTargets: ([HitTarget]) -> Void
    var onPanelHeight: (CGFloat) -> Void

    private var placement: Placement { state.placement }
    private var alignment: Alignment { placement.alignment }
    private var tone: UsageTone { UsageTone.forFraction(store.snapshot.peakFraction) }
    private var sessions: [AgentSession] { store.sessions }

    private var layout: Layout {
        Layout(placement: placement,
               providers: max(store.snapshot.visible.count, 1),
               sessions: sessions.count,
               leadProject: sessions.first?.project ?? "",
               leadDetail: sessions.first?.detail ?? "",
               measuredBody: state.panelBodyHeight,
               trailLabels: trailLabels)
    }

    /// What the trailing side will actually render, so the layout can measure it.
    private var trailLabels: [String] {
        store.snapshot.visible.map { provider in
            provider.headlineFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–"
        }
    }

    private var currentSize: CGSize { layout.size(for: state.mode) }
    private var radius: CGFloat { state.mode == .mini ? 4 : 12 }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            shell
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// One container that morphs between the three states. The states are stacked and
    /// cross-faded rather than swapped, so the black shape animates continuously
    /// instead of the tree being torn down and rebuilt mid-gesture.
    private var shell: some View {
        ZStack(alignment: alignment) {
            layer(MiniNub(tone: tone, layout: layout, working: sessions.anyWorking),
                  visible: state.mode == .mini)
            layer(PillContent(snapshot: store.snapshot, sessions: sessions, tone: tone, layout: layout),
                  visible: state.mode == .pill)
            layer(ExpandedContent(store: store, state: state, layout: layout, tone: tone,
                                  onHitTargets: onHitTargets, onHeight: reportHeight),
                  visible: state.mode == .expanded)
        }
        .frame(width: currentSize.width, height: currentSize.height, alignment: alignment)
        .background(Color.black)
        .clipShape(NotchShape(radius: radius, edge: placement.edge))
        .overlay(
            NotchShape(radius: radius, edge: placement.edge)
                .stroke(Color.white.opacity(state.mode == .expanded ? 0.10 : 0.06), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(state.mode == .expanded ? 0.5 : 0.22),
                radius: state.mode == .expanded ? 20 : 8, y: 6)
        .animation(Anim.morph, value: currentSize)
        .animation(Anim.morph, value: radius)
        .animation(Anim.morph, value: placement)
    }

    /// The panel measures itself; the shell, the window and the hit region all follow
    /// that number rather than a separate guess.
    private func reportHeight(_ height: CGFloat) {
        let rounded = ceil(height)
        guard abs((state.panelBodyHeight ?? 0) - rounded) > 0.5 else { return }
        state.panelBodyHeight = rounded
        onPanelHeight(rounded)
    }

    /// Hidden states stay in the tree at zero opacity — cheap, and it keeps the
    /// cross-fade from fighting the size animation.
    private func layer<V: View>(_ view: V, visible: Bool) -> some View {
        view
            .opacity(visible ? 1 : 0)
            .blur(radius: visible ? 0 : 3)
            .allowsHitTesting(visible)
            .animation(Anim.fade, value: visible)
    }
}

/// Work-mode nub: a sliver of colour, nothing else. It still reports whether an agent
/// is running, since that is the one thing worth knowing while hidden.
private struct MiniNub: View {
    var tone: UsageTone
    var layout: Layout
    var working: Bool

    var body: some View {
        let size = layout.size(for: .mini)
        let colour = working ? AgentKind.claude.tint : tone.color
        Group {
            if layout.placement.edge.isSide {
                VStack(spacing: 3) {
                    Capsule().fill(colour.opacity(0.85)).frame(width: 3, height: 16)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 3, height: 8)
                }
            } else {
                HStack(spacing: 3) {
                    Capsule().fill(colour.opacity(0.85)).frame(width: 16, height: 3)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 8, height: 3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Resting state. Island mode splits the readout either side of the cutout, the way
/// a Live Activity does; the other placements lay it out in one run.
private struct PillContent: View {
    var snapshot: UsageSnapshot
    var sessions: [AgentSession]
    var tone: UsageTone
    var layout: Layout

    private var lead: AgentSession? { sessions.first }

    var body: some View {
        let size = layout.size(for: .pill)
        Group {
            switch layout.placement.edge {
            case .island: island(size)
            case .left, .right: vertical(size)
            case .top: horizontal(size)
            }
        }
    }

    private func island(_ size: CGSize) -> some View {
        // Each wing centres its own content rather than pinning it outward, so nothing
        // ends up pressed against the rounded corner.
        let wing = (size.width - layout.notchGap) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let lead {
                    SessionChip(session: lead)
                        .fixedSize()
                    if sessions.count > 1 {
                        Text("+\(sessions.count - 1)")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                } else {
                    ActivityBars(tint: tone.color, animating: false)
                    Text("idle")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            .fixedSize()
            .padding(.horizontal, Style.wingInset)
            .frame(width: wing)

            // The hardware cutout lives in this gap.
            Color.clear.frame(width: layout.notchGap)

            UsageStrip(snapshot: snapshot, tone: tone, showToneBar: false, style: .rings)
                .fixedSize()
                .padding(.horizontal, Style.wingInset)
                .frame(width: wing)
        }
        .frame(width: size.width, height: size.height)
    }

    private func horizontal(_ size: CGSize) -> some View {
        HStack(spacing: 9) {
            if let lead {
                SessionChip(session: lead, showProject: false)
                if sessions.count > 1 {
                    Text("+\(sessions.count - 1)")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Divider().frame(height: 12).overlay(Color.white.opacity(0.12))
            }
            UsageStrip(snapshot: snapshot, tone: tone, showToneBar: false, style: .rings)
        }
        .fixedSize()
        .padding(.horizontal, Style.pillInset)
        .frame(width: size.width, height: size.height)
    }

    private func vertical(_ size: CGSize) -> some View {
        VStack(spacing: 8) {
            ForEach(sessions.prefix(2)) { session in
                ActivityBars(tint: session.kind.tint, animating: session.isWorking, height: 9)
            }
            ForEach(snapshot.visible) { provider in
                UsageRing(percent: provider.session.percent ?? provider.week.percent,
                          tint: provider.tint,
                          resetsAt: provider.session.resetsAt,
                          windowLength: provider.session.length,
                          diameter: 22)
            }
            Capsule().fill(tone.color.opacity(0.9)).frame(width: 12, height: 3)
        }
        .padding(.vertical, Style.sidePillInset)
        .frame(width: size.width, height: size.height)
    }
}

/// Opened panel: live sessions, their local workspaces, then the usage rings.
private struct ExpandedContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: NotchState
    var layout: Layout
    var tone: UsageTone
    var onHitTargets: ([HitTarget]) -> Void
    var onHeight: (CGFloat) -> Void

    var body: some View {
        let size = layout.size(for: .expanded)
        VStack(spacing: 0) {
            if layout.placement.edge.isIsland {
                // Reserve the band the hardware notch sits in, and use it the way a
                // Live Activity does rather than leaving dead black.
                islandBand
                    .frame(height: layout.placement.notch.height)
            }
            // No fixed height: the content lays out naturally and reports what it
            // needed, which is what everything else is then sized from.
            body(width: size.width)
                .fixedSize(horizontal: false, vertical: true)
                .background(RectReader { onHeight($0.height) })
        }
        .frame(width: size.width, alignment: .top)
    }

    private var islandBand: some View {
        let wing = (layout.size(for: .expanded).width - layout.notchGap) / 2
        return HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(store.snapshot.updatedAt == .distantPast ? "—" : Fmt.clock(store.snapshot.updatedAt))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(store.isRefreshing ? 0.9 : 0.45))
                    .rotationEffect(.degrees(state.spin))
            }
            .fixedSize()
            .lineLimit(1)
            .frame(width: wing)

            Color.clear.frame(width: layout.notchGap)

            UsageStrip(snapshot: store.snapshot, tone: tone, showToneBar: false)
                .fixedSize()
                .lineLimit(1)
                .frame(width: wing)
        }
    }

    private func body(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !layout.placement.edge.isIsland { header }

            if !store.sessions.isEmpty {
                sectionTitle("AGENTS")
                ForEach(store.sessions) { session in
                    SessionRow(session: session)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.vertical, 1)
            }

            if !store.workspaces.isEmpty {
                sectionTitle("WORKSPACES")
                ForEach(store.workspaces) { workspace in
                    WorkspaceRow(workspace: workspace)
                }
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.vertical, 1)
            }

            if store.snapshot.visible.isEmpty {
                Text(store.snapshot.providers.first?.footnote ?? "Looking for local sessions…")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(store.snapshot.visible.enumerated()), id: \.element.id) { index, provider in
                    if index > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.06))
                            .frame(height: 1)
                            .padding(.vertical, 1)
                    }
                    ProviderRow(provider: provider)
                }
            }
            footer
        }
        .padding(.horizontal, Style.panelInset)
        .padding(.top, layout.placement.edge.isIsland ? 6 : 12)
        .padding(.bottom, 12)
        .frame(width: width, alignment: .leading)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(.white.opacity(0.35))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("DEV COCKPIT")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(store.snapshot.updatedAt == .distantPast ? "—" : Fmt.clock(store.snapshot.updatedAt))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.35))
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(store.isRefreshing ? 0.9 : 0.5))
                .rotationEffect(.degrees(state.spin))
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: Settings.shared.miniMode ? "eye" : "eye.slash")
                    .font(.system(size: 9, weight: .bold))
                Text(Settings.shared.miniMode ? "Show pill" : "Work mode")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07), in: Capsule())
            .hitTarget("work-mode", report: onHitTargets)

            Spacer()

            Text("click to refresh")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.28))

            // The menu-bar icon is the first thing macOS hides when the bar is full,
            // which on a notched Mac is most of the time. Settings live here too.
            Image(systemName: "gearshape.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.07), in: Capsule())
                .hitTarget("settings", report: onHitTargets)
        }
    }
}

private struct ProviderRow: View {
    var provider: ProviderUsage

    private var tint: Color {
        let tone = UsageTone.forFraction(provider.headlineFraction)
        return tone == .calm ? provider.tint : tone.color
    }

    var body: some View {
        HStack(spacing: 11) {
            RingGauge(fraction: provider.session.fraction, tint: tint)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    ProviderBadge(glyph: provider.glyph, tint: provider.tint)
                    Text(provider.name)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                    if provider.session.estimated {
                        Text("est")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.white.opacity(0.08), in: Capsule())
                            .help("Claude Code does not publish plan limits locally; this ring compares the current 5-hour block against your ceiling.")
                    }
                    Spacer(minLength: 0)
                    if let reset = Fmt.countdown(to: provider.session.resetsAt) {
                        Text(reset)
                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }

                HStack(spacing: 6) {
                    Text(provider.week.label)
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                    MeterBar(fraction: provider.week.fraction, tint: provider.tint)
                    if let p = provider.week.percent {
                        Text("\(p)%")
                            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }

                Text(detail)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
        }
    }

    private var detail: String {
        var bits: [String] = []
        if provider.tokens > 0 { bits.append("\(Fmt.tokens(provider.tokens)) tok") }
        if let cost = provider.costUSD, cost > 0 { bits.append("~\(Fmt.money(cost))") }
        if let plan = provider.plan { bits.append(plan) }
        if let note = provider.footnote { bits.append(note) }
        return bits.isEmpty ? "no activity yet" : bits.joined(separator: " · ")
    }
}

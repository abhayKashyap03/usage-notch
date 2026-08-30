import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: NotchState
    var onRefresh: () -> Void
    var onToggleMini: () -> Void
    var onHitTargets: ([HitTarget]) -> Void

    static let space = "usage-notch"

    private var tone: UsageTone { UsageTone.forFraction(store.snapshot.peakFraction) }
    private var providers: Int { max(store.snapshot.visible.count, 1) }
    private var expandedSize: CGSize { NotchMode.expandedSize(providers: providers) }
    private var currentSize: CGSize { state.mode.size(edge: placement.edge, providers: providers) }
    private var radius: CGFloat { state.mode == .mini ? 4 : 12 }
    private var placement: Placement { state.placement }
    private var alignment: Alignment { placement.alignment }

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
            layer(MiniNub(tone: tone, edge: placement.edge), visible: state.mode == .mini)
            layer(PillContent(snapshot: store.snapshot, tone: tone, edge: placement.edge),
                  visible: state.mode == .pill)
            layer(
                ExpandedContent(store: store, state: state, size: expandedSize,
                                onHitTargets: onHitTargets),
                visible: state.mode == .expanded
            )
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

/// Work-mode nub: a sliver of colour, nothing else.
private struct MiniNub: View {
    var tone: UsageTone
    var edge: NotchEdge

    var body: some View {
        let size = NotchMode.mini.size(edge: edge)
        Group {
            if edge.isSide {
                VStack(spacing: 3) {
                    Capsule().fill(tone.color.opacity(0.85)).frame(width: 3, height: 16)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 3, height: 8)
                }
            } else {
                HStack(spacing: 3) {
                    Capsule().fill(tone.color.opacity(0.85)).frame(width: 16, height: 3)
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 8, height: 3)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Resting pill: one compact reading per provider.
private struct PillContent: View {
    var snapshot: UsageSnapshot
    var tone: UsageTone
    var edge: NotchEdge

    var body: some View {
        edge.isSide ? AnyView(vertical) : AnyView(horizontal)
    }

    /// Side-mounted: readings stack down the pill so no text has to rotate.
    private var vertical: some View {
        let size = NotchMode.pill.size(edge: edge, providers: max(snapshot.visible.count, 1))
        return VStack(spacing: 7) {
            ForEach(snapshot.visible) { provider in
                VStack(spacing: 2) {
                    Circle().fill(provider.tint).frame(width: 5, height: 5)
                    Text(provider.headlineFraction.map { "\(Int(($0 * 100).rounded()))" } ?? "–")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .contentTransition(.numericText())
                }
            }
            if snapshot.visible.isEmpty {
                Text("–")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Capsule().fill(tone.color.opacity(0.9)).frame(width: 12, height: 3)
        }
        .padding(.vertical, 8)
        .frame(width: size.width, height: size.height)
    }

    private var horizontal: some View {
        HStack(spacing: 10) {
            ForEach(snapshot.visible) { provider in
                HStack(spacing: 5) {
                    Circle()
                        .fill(provider.tint)
                        .frame(width: 5, height: 5)
                    if let percent = provider.headlineFraction.map({ Int(($0 * 100).rounded()) }) {
                        Text("\(percent)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .contentTransition(.numericText())
                    } else {
                        Text("–")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            if snapshot.visible.isEmpty {
                Text("no data")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 0)
            Capsule()
                .fill(tone.color.opacity(0.9))
                .frame(width: 14, height: 3)
        }
        .padding(.horizontal, 11)
        .frame(width: NotchMode.pill.size(edge: .top).width,
               height: NotchMode.pill.size(edge: .top).height)
    }
}

/// Opened panel: full rings, windows, spend and reset countdowns.
private struct ExpandedContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var state: NotchState
    var size: CGSize
    var onHitTargets: ([HitTarget]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
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
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("LLM USAGE")
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

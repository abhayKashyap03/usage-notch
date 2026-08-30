import SwiftUI

/// Three bars that bounce while an agent is working, and flatten when it stops.
/// The notch equivalent of the little equaliser a music app shows.
struct ActivityBars: View {
    var tint: Color
    var animating: Bool
    var height: CGFloat = 11

    @State private var phase = false

    private let scales: [CGFloat] = [0.45, 1.0, 0.7]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(scales.enumerated()), id: \.offset) { index, scale in
                Capsule()
                    .fill(tint)
                    .frame(width: 2, height: barHeight(index: index, scale: scale))
                    .animation(
                        animating
                            ? .easeInOut(duration: 0.42 + Double(index) * 0.09).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.2),
                        value: phase
                    )
            }
        }
        .frame(height: height)
        .onAppear { phase = animating }
        .onChange(of: animating) { _, now in phase = now }
    }

    private func barHeight(index: Int, scale: CGFloat) -> CGFloat {
        guard animating else { return 3 }
        let low = height * 0.3 * scale
        let high = height * scale
        return phase ? high : max(low, 3)
    }
}

/// One live session, compact: what it is doing and where.
struct SessionChip: View {
    var session: AgentSession
    var showProject = true

    var body: some View {
        HStack(spacing: 5) {
            ActivityBars(tint: session.kind.tint, animating: session.isWorking)
            VStack(alignment: .leading, spacing: 0) {
                if showProject {
                    Text(session.project)
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Text(session.detail)
                    .font(.system(size: showProject ? 8.5 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(session.isWorking ? 0.6 : 0.38))
                    .lineLimit(1)
            }
        }
    }
}

/// One row in the open panel.
struct SessionRow: View {
    var session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            ActivityBars(tint: session.kind.tint, animating: session.isWorking, height: 13)
                .frame(width: 12)

            Text(session.project)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            if let branch = session.branch {
                Text(branch)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(session.detail)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(session.isWorking ? session.kind.tint.opacity(0.95) : .white.opacity(0.35))
                .lineLimit(1)

            Text(Fmt.elapsed(session.elapsed))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(height: 18)
    }
}

/// Compact usage readout: one dot and percentage per provider.
struct UsageStrip: View {
    var snapshot: UsageSnapshot
    var tone: UsageTone
    var showToneBar = true

    var body: some View {
        HStack(spacing: 9) {
            ForEach(snapshot.visible) { provider in
                HStack(spacing: 4) {
                    Circle().fill(provider.tint).frame(width: 5, height: 5)
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
            if showToneBar {
                Capsule().fill(tone.color.opacity(0.9)).frame(width: 14, height: 3)
            }
        }
    }
}

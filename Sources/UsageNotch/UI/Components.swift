import SwiftUI

/// The notch silhouette: flush against the screen edge it is attached to, rounded
/// on the sides that face the desktop.
struct NotchShape: Shape {
    var radius: CGFloat = 12
    var edge: NotchEdge = .top

    /// Animatable so the corner can round down as the pill collapses to the nub.
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let c = Placement(edge: edge, anchor: .center).radii(min(radius, limit))
        var p = Path()

        p.move(to: CGPoint(x: rect.minX + c.topLeft, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - c.topRight, y: rect.minY))
        if c.topRight > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + c.topRight),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c.bottomRight))
        if c.bottomRight > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.maxX - c.bottomRight, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX + c.bottomLeft, y: rect.maxY))
        if c.bottomLeft > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - c.bottomLeft),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c.topLeft))
        if c.topLeft > 0 {
            p.addQuadCurve(to: CGPoint(x: rect.minX + c.topLeft, y: rect.minY),
                           control: CGPoint(x: rect.minX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// Circular gauge used for the 5-hour window.
struct RingGauge: View {
    var fraction: Double?
    var tint: Color
    var diameter: CGFloat = 38
    var lineWidth: CGFloat = 4

    private var clamped: Double { min(max(fraction ?? 0, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.55), tint],
                                    center: .center,
                                    startAngle: .degrees(-90),
                                    endAngle: .degrees(270)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.5, dampingFraction: 0.85), value: clamped)

            if let percent = fraction.map({ Int(($0 * 100).rounded()) }) {
                Text("\(percent)")
                    .font(.system(size: diameter * 0.30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .contentTransition(.numericText())
            } else {
                Text("–")
                    .font(.system(size: diameter * 0.30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

/// Slim horizontal meter used for the weekly window.
struct MeterBar: View {
    var fraction: Double?
    var tint: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint.opacity(0.9))
                    .frame(width: geo.size.width * min(max(fraction ?? 0, 0), 1))
                    .animation(.spring(response: 0.5, dampingFraction: 0.85), value: fraction ?? 0)
            }
        }
        .frame(height: height)
    }
}

/// Two-letter provider badge.
struct ProviderBadge: View {
    var glyph: String
    var tint: Color

    var body: some View {
        Text(glyph)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Compact readout for the collapsed pill: a ring that fills as the window runs
/// down, with the usage percentage inside it.
///
/// Two different quantities share one glyph on purpose — the number answers "how
/// much have I used", the arc answers "how long until it resets", and those are the
/// only two things worth knowing at a glance.
struct UsageRing: View {
    var percent: Int?
    var tint: Color
    var resetsAt: Date?
    var windowLength: TimeInterval?
    var diameter: CGFloat = 20

    var body: some View {
        // Redraws on its own so the arc creeps forward between usage refreshes.
        TimelineView(.periodic(from: .now, by: 20)) { context in
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.13), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: elapsed(now: context.date))
                    .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(percent.map(String.init) ?? "–")
                    .font(.system(size: diameter * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .contentTransition(.numericText())
            }
            .frame(width: diameter, height: diameter)
        }
    }

    private func elapsed(now: Date) -> CGFloat {
        guard let resetsAt, let windowLength, windowLength > 0 else { return 0 }
        let remaining = resetsAt.timeIntervalSince(now)
        return CGFloat(min(max(1 - remaining / windowLength, 0), 1))
    }
}

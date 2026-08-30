import SwiftUI
import Combine

enum NotchMode: Equatable {
    case mini        // "work mode": a nub that stays out of the way
    case pill        // resting state
    case expanded    // hovered / opened

}

/// One place for the motion curves so the shape, the contents and the shadow all
/// move on the same timing.
enum Anim {
    /// Shape morph between states. Slightly under-damped for a bit of settle.
    static let morph = Animation.spring(response: 0.36, dampingFraction: 0.80)
    /// Content cross-fade; shorter than the morph so text never lingers mid-resize.
    static let fade = Animation.easeOut(duration: 0.16)
}

/// Shared UI state between the AppKit panel and the SwiftUI tree.
@MainActor
final class NotchState: ObservableObject {
    @Published var mode: NotchMode = .pill
    @Published var placement: Placement = .current
    @Published var isHovering = false
    /// Height the open panel's content measured, once SwiftUI has laid it out.
    @Published var panelBodyHeight: CGFloat?
    /// Accumulates 360° per refresh so the icon keeps spinning in one direction.
    @Published var spin: Double = 0

    private var collapseWork: DispatchWorkItem?

    var restingMode: NotchMode { Settings.shared.miniMode ? .mini : .pill }

    func hoverChanged(_ inside: Bool) {
        isHovering = inside
        collapseWork?.cancel()
        if inside {
            guard mode != .expanded else { return }
            withAnimation(Anim.morph) { mode = .expanded }
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isHovering else { return }
                withAnimation(Anim.morph) { self.mode = self.restingMode }
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    func settleToResting() {
        withAnimation(Anim.morph) { mode = restingMode }
    }

    func kickRefreshSpin() {
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.7)) { spin += 360 }
    }
}

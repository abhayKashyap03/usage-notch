import AppKit
import SwiftUI

/// A clickable region inside the panel, published from SwiftUI so the AppKit layer
/// can route clicks itself.
///
/// The panel never becomes key, and SwiftUI's own gesture recognisers do not fire in
/// a non-key `NSPanel`. Rather than making the pill steal keyboard focus, the few
/// controls it has report their rects and the hosting view dispatches by hit test.
struct HitTarget: Equatable {
    var id: String
    var rect: CGRect
}

/// Measures the view it is attached to and reports the rect through a closure.
///
/// Preferences are not usable here: SwiftUI drops values written inside `.background`
/// and `.overlay`, and stacking the reader as a sibling makes the layout greedy
/// (a `GeometryReader` expands to fill). Attaching this as a background keeps the
/// measured view's own size and reports out of band instead.
struct RectReader: View {
    var onChange: (CGRect) -> Void

    var body: some View {
        GeometryReader { proxy in
            let rect = proxy.frame(in: .global)
            Color.clear
                .onAppear { publish(rect) }
                .onChange(of: rect) { _, new in publish(new) }
        }
    }

    private func publish(_ rect: CGRect) {
        // Never mutate observed state inside a layout pass.
        DispatchQueue.main.async { onChange(rect) }
    }
}

extension View {
    /// Reports this view's rect as a clickable target for the AppKit layer.
    func hitTarget(_ id: String, report: @escaping ([HitTarget]) -> Void) -> some View {
        background(RectReader { rect in report([HitTarget(id: id, rect: rect)]) })
    }
}

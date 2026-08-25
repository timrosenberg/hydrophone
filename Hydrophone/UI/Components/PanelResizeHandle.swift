import SwiftUI

/// A thin invisible grab strip along the Now Playing panel's leading edge:
/// drag to resize the panel, with the standard left-right resize cursor on
/// hover. Replaces the drag-to-resize that was lost when the panel moved off
/// `.inspector` (see docs/04) — this lives entirely inside the detail column,
/// so resizing never touches the split view or the toolbar.
struct PanelResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// Which edge of the panel this handle sits on: `.trailing` for a panel
    /// anchored to the trailing edge of its container (dragging left widens
    /// it), `.leading` for one anchored to the leading edge (dragging right
    /// widens it).
    let anchoredEdge: HorizontalEdge

    /// Panel width at drag start; increments apply to this, not the live
    /// value, so the handle tracks the cursor exactly.
    @State private var baseWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 9)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = baseWidth ?? width
                        baseWidth = base
                        width = anchoredEdge == .trailing
                            ? (base - value.translation.width).clamped(to: range)
                            : (base + value.translation.width).clamped(to: range)
                    }
                    .onEnded { _ in baseWidth = nil }
            )
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

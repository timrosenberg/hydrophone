import SwiftUI
import AppKit

/// Read-only text with reliable native click-drag selection and Copy.
/// SwiftUI's `.textSelection(.enabled)` (issue #44) showed the right I-beam
/// cursor but drag-select was flaky inside `TrackInfoView`'s `Form` — likely
/// fighting the Form's own gesture handling. A plain non-editable, selectable
/// `NSTextField` (the standard "selectable label" recipe) sidesteps that
/// entirely, the same way `MusicTrackTable` drops to AppKit for behavior
/// SwiftUI can't deliver on its own.
struct SelectableText: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var color: NSColor = .labelColor
    /// 1 = single line, truncating; anything else wraps.
    var maximumNumberOfLines: Int = 1

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        apply(to: field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        apply(to: field)
    }

    // Without this, an NSViewRepresentable reports its unconstrained
    // intrinsic size (the full unwrapped text width) regardless of the space
    // SwiftUI actually offers it — which starved the artwork of its layout
    // priority in `TrackInfoView`'s header HStack and left a long title
    // un-wrapped and clipped instead of respecting `maximumNumberOfLines`.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.intrinsicContentSize.width
        nsView.preferredMaxLayoutWidth = maximumNumberOfLines == 1 ? 0 : width
        let fitting = nsView.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(fitting.width, width), height: fitting.height)
    }

    private func apply(to field: NSTextField) {
        field.font = font
        field.textColor = color
        field.maximumNumberOfLines = maximumNumberOfLines
        let wraps = maximumNumberOfLines != 1
        field.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        field.cell?.wraps = wraps
        field.cell?.truncatesLastVisibleLine = true
    }
}

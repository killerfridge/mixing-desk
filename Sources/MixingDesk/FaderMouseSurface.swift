import SwiftUI
import AppKit

// Handle the native click count explicitly. A zero-distance SwiftUI drag can
// otherwise win recognition before the double-tap gesture ever receives it.
struct FaderMouseSurface: NSViewRepresentable {
    var onPosition: (CGFloat) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: MouseView, context: Context) {
        view.onPosition = onPosition
        view.onReset = onReset
    }

    final class MouseView: NSView {
        var onPosition: (CGFloat) -> Void = { _ in }
        var onReset: () -> Void = {}
        private var resetting = false
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            resetting = event.clickCount >= 2
            if resetting { onReset() }
            else { onPosition(convert(event.locationInWindow, from: nil).y) }
        }
        override func mouseDragged(with event: NSEvent) {
            if !resetting { onPosition(convert(event.locationInWindow, from: nil).y) }
        }
        override func mouseUp(with event: NSEvent) { resetting = false }
    }
}

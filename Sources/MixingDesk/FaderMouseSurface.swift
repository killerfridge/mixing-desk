import SwiftUI
import AppKit

// Handle the native click count explicitly. A zero-distance SwiftUI drag can
// otherwise win recognition before the double-tap gesture ever receives it.
struct FaderMouseSurface: NSViewRepresentable {
    var currentPosition: () -> CGFloat
    var onPosition: (CGFloat, Bool) -> Void
    var onReset: () -> Void

    func makeNSView(context: Context) -> MouseView {
        let view = MouseView()
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: MouseView, context: Context) {
        view.currentPosition = currentPosition
        view.onPosition = onPosition
        view.onReset = onReset
    }

    final class MouseView: NSView {
        var onPosition: (CGFloat, Bool) -> Void = { _, _ in }
        var onReset: () -> Void = {}
        var currentPosition: () -> CGFloat = { 0 }
        private var resetting = false
        private var fine = false
        private var anchorY: CGFloat = 0, anchorPosition: CGFloat = 0
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(nil)
            resetting = event.clickCount >= 2
            let y = convert(event.locationInWindow, from: nil).y
            fine = event.modifierFlags.contains(.shift); anchorY = y; anchorPosition = currentPosition()
            if resetting { onReset() }
            else if !fine { onPosition(y, false) }
        }
        override func mouseDragged(with event: NSEvent) {
            guard !resetting else { return }
            let y = convert(event.locationInWindow, from: nil).y
            let nextFine = event.modifierFlags.contains(.shift)
            if nextFine != fine { anchorY = y; anchorPosition = currentPosition(); fine = nextFine }
            onPosition(fine ? anchorPosition + (y-anchorY)*0.1 : y, fine)
        }
        override func mouseUp(with event: NSEvent) { resetting = false }
    }
}

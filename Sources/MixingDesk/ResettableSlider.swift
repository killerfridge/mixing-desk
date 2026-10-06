import SwiftUI
import AppKit

/// Native tracking preserves dragging, keyboard and accessibility behavior while
/// recognizing a double click before NSSlider starts its tracking loop.
struct ResettableSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double = 0
    var label: String
    var defaultDescription = "0 dB"
    var onEditingChanged: ((Bool) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> ResetSlider {
        let slider = ResetSlider()
        slider.isContinuous = true; slider.controlSize = .mini
        slider.target = context.coordinator; slider.action = #selector(Coordinator.changed(_:))
        slider.setAccessibilityLabel(label)
        return slider
    }
    func updateNSView(_ slider: ResetSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.doubleValue = value; slider.defaultValue = defaultValue
        slider.trackingChanged = onEditingChanged
        slider.setAccessibilityLabel(label)
        slider.toolTip = "Shift-drag for fine adjustment. Double-click to reset to \(defaultDescription)."
    }
    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    final class ResetSlider: NSSlider {
        var defaultValue: Double = 0
        var trackingChanged: ((Bool) -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            trackingChanged?(true)
            defer { trackingChanged?(false) }
            if event.clickCount >= 2 {
                doubleValue = defaultValue
                if let action { sendAction(action, to: target) }
            } else if event.modifierFlags.contains(.shift), let window {
                // Native slider tracking jumps to the click. Fine tracking is
                // relative to the current value, with the same begin/end hooks.
                let anchor = convert(event.locationInWindow, from: nil).x
                let initial = doubleValue
                let travel = max(1, bounds.width - ((cell as? NSSliderCell)?.knobThickness ?? 12))
                while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
                    if next.type == .leftMouseUp { break }
                    let delta = convert(next.locationInWindow, from: nil).x - anchor
                    doubleValue = min(maxValue, max(minValue, initial + Double(delta/travel)*(maxValue-minValue)*0.1))
                    if let action { sendAction(action, to: target) }
                }
            } else { super.mouseDown(with: event) }
        }
    }
}

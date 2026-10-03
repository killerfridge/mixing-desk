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
        slider.setAccessibilityLabel(label)
        slider.toolTip = "Double-click to reset to \(defaultDescription)."
    }
    final class Coordinator: NSObject {
        var parent: ResettableSlider
        init(_ parent: ResettableSlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.doubleValue }
    }
    final class ResetSlider: NSSlider {
        var defaultValue: Double = 0
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                doubleValue = defaultValue
                if let action { sendAction(action, to: target) }
            } else { super.mouseDown(with: event) }
        }
    }
}

import SwiftUI
import AppKit

/// One validation and commit path for Desk and Pipeline level readouts. Native
/// field editing keeps keyboard selection, focus loss, and accessibility intact.
struct NumericLevelEditor: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    var size: CGFloat = 10
    var muted = false
    var onEditingChanged: ((Bool) -> Void)? = nil

    static func parsed(_ text: String, range: ClosedRange<Double>) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")
        guard let number = Double(input), number.isFinite, range.contains(number) else { return nil }
        return number
    }
    static func display(_ value: Double) -> String {
        value <= -90 ? "−∞ dB" : String(format: "%+.2f dB", value)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = LevelField()
        let coordinator = context.coordinator
        field.onBegin = { coordinator.begin($0) }
        field.isBordered = false; field.drawsBackground = false; field.alignment = .right
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: .medium)
        field.textColor = muted ? .secondaryLabelColor : .labelColor
        field.setAccessibilityLabel(label)
        field.toolTip = "Enter a level from \(range.lowerBound) to \(range.upperBound) dB. Enter or leaving the field commits; Escape cancels."
        if !context.coordinator.editing { field.stringValue = Self.display(value) }
    }
    final class LevelField: NSTextField {
        var onBegin: ((NSTextField) -> Void)?
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onBegin?(self) }
            return accepted
        }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NumericLevelEditor
        var editing = false
        init(_ parent: NumericLevelEditor) { self.parent = parent }
        func controlTextDidBeginEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { begin(field) }
        }
        func begin(_ field: NSTextField) {
            guard !editing else { return }
            editing = true; parent.onEditingChanged?(true)
            field.currentEditor()?.string = String(parent.value)
            (field.currentEditor() as? NSTextView)?.selectAll(nil)
        }
        func finish(_ field: NSTextField, cancel: Bool = false) {
            guard editing else { return }
            if !cancel, let number = NumericLevelEditor.parsed(field.currentEditor()?.string ?? field.stringValue, range: parent.range) {
                parent.value = number
            }
            editing = false; parent.onEditingChanged?(false)
            let display = NumericLevelEditor.display(parent.value)
            field.currentEditor()?.string = display; field.stringValue = display
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { finish(field) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:)) {
                finish(field, cancel: selector == #selector(NSResponder.cancelOperation(_:)))
                field.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}

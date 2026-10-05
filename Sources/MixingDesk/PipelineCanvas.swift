import AppKit
import SwiftUI
import DeskModels

/// Observes navigation only inside this view's bounds and window. Node controls
/// retain ordinary AppKit/SwiftUI hit testing; no global event tap is installed.
struct PipelineNavigation: NSViewRepresentable {
    var scroll: (CGSize, CGPoint, Bool) -> Void
    var magnify: (CGFloat, CGPoint) -> Void
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) { view.scroll = scroll; view.magnify = magnify }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.stop() }
    final class Surface: NSView {
        var scroll: ((CGSize, CGPoint, Bool) -> Void)?
        var magnify: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, event.window === self.window, self.window?.attachedSheet == nil else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                if event.type == .magnify { self.magnify?(event.magnification, p) }
                else { self.scroll?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY), p, event.modifierFlags.contains(.command)) }
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
        deinit { stop() }
    }
}

enum PipelineGeometry {
    static let card = CGSize(width: 240, height: 218)
    static let portY: CGFloat = 64
    static func port(_ position: PipelinePosition, output: Bool) -> CGPoint { CGPoint(x: position.x + (output ? card.width : 0), y: position.y + portY) }
    static func controls(_ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGPoint) {
        let bend = max(80, abs(b.x - a.x) * 0.5)
        return (CGPoint(x: a.x + bend, y: a.y), CGPoint(x: b.x - bend, y: b.y))
    }
    static func path(_ a: CGPoint, _ b: CGPoint) -> Path {
        let (c, d) = controls(a, b)
        return Path { p in p.move(to: a); p.addCurve(to: b, control1: c, control2: d) }
    }
    static func hit(_ point: CGPoint, from a: CGPoint, to b: CGPoint, tolerance: CGFloat) -> Bool {
        let (c, d) = controls(a, b)
        var previous = a
        for i in 1...40 {
            let t = CGFloat(i)/40, u = 1-t
            let next = CGPoint(x: u*u*u*a.x + 3*u*u*t*c.x + 3*u*t*t*d.x + t*t*t*b.x,
                               y: u*u*u*a.y + 3*u*u*t*c.y + 3*u*t*t*d.y + t*t*t*b.y)
            let dx = next.x-previous.x, dy = next.y-previous.y
            let l = dx*dx+dy*dy
            let f = l > 0 ? min(1, max(0, ((point.x-previous.x)*dx+(point.y-previous.y)*dy)/l)) : 0
            if hypot(point.x-previous.x-f*dx, point.y-previous.y-f*dy) <= tolerance { return true }
            previous = next
        }
        return false
    }
}

struct PipelineWires: View {
    let graph: PipelineGraph
    let session: Session
    let positions: [String: PipelinePosition]
    let trace: PipelineTrace?
    let selected: PipelineConnection?
    let connecting: PipelineNodeID?
    let pointer: CGPoint?
    var body: some View {
        Canvas { context, _ in
            for edge in graph.edges {
                guard let from = positions[edge.source.key], let to = positions[edge.destination.key] else { continue }
                let blocked = graph.directlyExcluded(edge, in: session) || trace?.excluded.contains(edge.id) == true
                let focused = selected == edge.id || trace?.reached.contains(edge.id) == true
                let sourceColor = session.strips.first { $0.id == edge.source.rawID }?.color ?? "amber"
                let color: Color = blocked ? .orange : DeskStyle.color(sourceColor)
                let opacity = edge.off ? 0.22 : (trace != nil && !focused ? 0.12 : focused ? 1 : 0.55)
                let a = PipelineGeometry.port(from, output: true), b = PipelineGeometry.port(to, output: false)
                context.stroke(PipelineGeometry.path(a, b), with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: focused ? 3 : 1.8, lineCap: .round, dash: edge.off || blocked ? [5, 5] : []))
                // Direction is visible without animated particles or per-edge meters.
                var arrow = Path(); arrow.move(to: CGPoint(x: b.x-9, y: b.y-4)); arrow.addLine(to: b); arrow.addLine(to: CGPoint(x: b.x-9, y: b.y+4))
                context.stroke(arrow, with: .color(color.opacity(opacity)), lineWidth: 1.5)
                if blocked {
                    let badge = CGRect(x: b.x-26, y: b.y-7, width: 14, height: 14)
                    context.fill(Path(ellipseIn: badge), with: .color(DeskStyle.background))
                    context.stroke(Path(ellipseIn: badge), with: .color(.orange), lineWidth: 1)
                    var slash = Path(); slash.move(to: CGPoint(x: b.x-23, y: b.y+4)); slash.addLine(to: CGPoint(x: b.x-15, y: b.y-4))
                    context.stroke(slash, with: .color(.orange), lineWidth: 1)
                }
            }
            if let connecting, let p = positions[connecting.key], let pointer {
                context.stroke(PipelineGeometry.path(PipelineGeometry.port(p, output: true), pointer), with: .color(DeskStyle.accent), style: StrokeStyle(lineWidth: 2, dash: [5,4]))
            }
        }.accessibilityHidden(true)
    }
}

/// Only this small leaf subscribes to 30 Hz readings.
struct PipelineMeter: View {
    @ObservedObject var readings: DeskMeters
    let index: Int?
    let isBus: Bool
    let running: Bool
    var body: some View {
        let values = isBus ? readings.value.buses : readings.value.strips
        let value = running && index.map { values.indices.contains($0) } == true ? values[index!] : MeterValue()
        HStack(spacing: 5) {
            GeometryReader { g in
                VStack(spacing: 2) {
                    bar(value.peakL, width: g.size.width)
                    bar(value.peakR, width: g.size.width)
                }
            }.frame(height: 9)
            Circle().fill(value.clip ? .red : Color.white.opacity(0.08)).frame(width: 5, height: 5)
        }.accessibilityLabel("\(isBus ? "Bus" : "Channel") level meter\(value.clip ? ", clipping" : "")")
    }
    private func bar(_ value: Float, width: CGFloat) -> some View {
        let level = min(1, max(0, (20 * log10(max(0.00001, Double(value))) + 60) / 60))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.06))
            Capsule().fill(value >= 1 ? .red : Color.green.opacity(0.75)).frame(width: width * level)
        }.frame(height: 3)
    }
}

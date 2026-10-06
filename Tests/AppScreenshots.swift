import AppKit
import SwiftUI
import DeskModels

@main struct AppScreenshots {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MixingDesk-Documentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = DeskStore(startsMonitoring: false, supportDirectory: temporary)
        precondition(store.showingSetupGuide && !store.running && !store.wantsRunning)
        precondition(store.session.monitorDeviceUID.isEmpty && store.session.routes.isEmpty)

        // A previously saved desk must bypass first-run setup and retain all
        // identities, routes, plugin state, and instrument channels.
        var saved = store.session
        var guitar = ChannelStrip(name: "My instrument"); guitar.role = "guitar"; guitar.source.deviceUID = "offline-interface"
        saved.strips.insert(guitar, at: 1)
        saved.monitorDeviceUID = "offline-output"
        saved.routes = [OutputRoute(sourceID: saved.buses[0].id, destinationUID: saved.monitorDeviceUID)]
        store.session = saved; store.saveLastSession()
        let restored = DeskStore(startsMonitoring: false, supportDirectory: temporary)
        precondition(!restored.showingSetupGuide && restored.session == saved && !restored.wantsRunning)

        let mono = Device(["uid": "mono", "name": "Mono output", "outputs": ["Output"], "supports48k": true])
        store.devices = [mono]; store.chooseMonitor("mono")
        precondition(store.session.routes.last?.channels == [0])
        store.devices = []; store.session = .starter(); store.showingSetupGuide = false
        store.driverStatus = DriverStatus(["state": "missing", "message": "Optional driver not installed. Run the Mixing Desk installer and select Mixing Desk Audio if you need virtual microphone or recording devices."])

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(ContentView().environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("desk.png"))
        try render(ContentView().environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("desk-light.png"), scheme: .light)
        try render(SetupGuide().environmentObject(store), size: NSSize(width: 706, height: 626), to: directory.appendingPathComponent("setup.png"))
        PipelineFixture.populate(store)
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 1280, height: 900), to: directory.appendingPathComponent("pipeline.png"))
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 800, height: 520), to: directory.appendingPathComponent("pipeline-compact.png"))
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 1280, height: 900), to: directory.appendingPathComponent("pipeline-light.png"), scheme: .light)
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 800, height: 520), to: directory.appendingPathComponent("pipeline-compact-light.png"), scheme: .light)
        try render(ContentView(initialPage: "Patching").environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("patching-light.png"), scheme: .light)
        // Quality-of-life review uses synthetic held peaks/limiting and no IO.
        store.session.strips[0].solo = true; store.session.strips[1].solo = true
        store.session.strips[0].faderDB = -6.25; store.session.strips[1].limiterEnabled = false
        store.apply()
        store.wantsRunning = true
        store.receiveStatus([
            "running": true, "estimatedLatencyMs": 5.3, "bufferFrames": 128, "protectionLatencyFrames": 96,
            "strips": store.session.strips.enumerated().map { i, strip in
                ["id": strip.id, "peakL": 0.7, "peakR": 0.6, "rmsL": 0.3, "rmsR": 0.25, "heldL": i == 1 ? 1.1 : 0.89125, "heldR": 0.7, "reductionDB": i == 0 ? 6.2 : 0, "clip": i == 1] as [String: Any]
            },
            "buses": store.session.buses.map { ["id": $0.id, "peakL": 0.8, "peakR": 0.7, "rmsL": 0.4, "rmsR": 0.3, "heldL": 1.2, "heldR": 1.1, "clip": true] as [String: Any] },
            "outputProtection": [["id": "fixture-group", "heldL": 0.89125, "reductionDB": 3.2, "destinations": [["uid": "fixture.headphones", "name": "Headphones · Ch 1 / 2"]]]]
        ])
        for scheme in [ColorScheme.light, .dark] {
            let appearance = scheme == .light ? "light" : "dark"
            try render(ContentView().environmentObject(store), size: NSSize(width: 800, height: 520), to: directory.appendingPathComponent("qol-compact-\(appearance).png"), scheme: scheme)
            try render(ContentView().environmentObject(store), size: NSSize(width: 1440, height: 1050), to: directory.appendingPathComponent("qol-comfortable-\(appearance).png"), scheme: scheme)
            try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 1280, height: 900), to: directory.appendingPathComponent("qol-pipeline-\(appearance).png"), scheme: scheme)
            try render(ContentView().environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("qol-numeric-entry-\(appearance).png"), scheme: scheme) { view, window in
                @MainActor func find(_ view: NSView) -> NSTextField? {
                    if let field = view as? NSTextField, field.accessibilityLabel() == "Microphone fader" { return field }
                    return view.subviews.lazy.compactMap { find($0) }.first
                }
                if let field = find(view) {
                    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(field)
                    field.currentEditor()?.string = "-6.375"
                    (field.currentEditor() as? NSTextView)?.selectAll(nil)
                }
            }
            try render(ContentView().environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("qol-shift-drag-\(appearance).png"), scheme: scheme) { view, window in
                @MainActor func surfaces(_ view: NSView) -> [FaderMouseSurface.MouseView] {
                    if let surface = view as? FaderMouseSurface.MouseView { return [surface] }
                    return view.subviews.flatMap { surfaces($0) }
                }
                guard let surface = surfaces(view).min(by: { $0.convert(.zero, to: nil).x < $1.convert(.zero, to: nil).x }) else { preconditionFailure("Review must expose a native fader") }
                let value = store.session.strips[0].faderDB
                let start = surface.convert(NSPoint(x: 30, y: 25), to: nil)
                let end = surface.convert(NSPoint(x: 30, y: 65), to: nil)
                @MainActor func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [.shift], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
                }
                surface.mouseDown(with: mouse(.leftMouseDown, at: start))
                precondition(store.session.strips[0].faderDB == value, "Fine tracking must not jump")
                surface.mouseDragged(with: mouse(.leftMouseDragged, at: end)); surface.mouseUp(with: mouse(.leftMouseUp, at: end))
                precondition(store.session.strips[0].faderDB != value, "Fine fader tracking must change the rendered level")
            }
        }
        store.clearAllSolos()
        try render(ContentView().environmentObject(store), size: NSSize(width: 800, height: 520), to: directory.appendingPathComponent("qol-solos-cleared.png"))
        store.running = false; store.wantsRunning = false
        store.session.strips[0].inserts = (0..<4).map { _ in .equalizer() }
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 1280, height: 900), to: directory.appendingPathComponent("pipeline-four-inserts-light.png"), scheme: .light)
        PipelineFixture.populate(store, dense: true)
        try render(ContentView(initialPage: "Pipeline").environmentObject(store), size: NSSize(width: 1280, height: 900), to: directory.appendingPathComponent("pipeline-dense.png"))
        print("PASS: first-run setup, saved-session preservation, mono output patch; rendered actual SwiftUI desk, setup and simple/compact/dense pipeline views without hardware IO or personal session data")
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, to url: URL, scheme: ColorScheme = .dark, beforeCapture: (@MainActor (NSView, NSWindow) -> Void)? = nil) throws {
        let suite = "MixingDesk-Screenshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(scheme == .dark ? "Dark" : "Light", forKey: "deskAppearance")
        let hosting = NSHostingView(rootView: view.defaultAppStorage(defaults).environment(\.colorScheme, scheme).preferredColorScheme(scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        beforeCapture?(hosting, window)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }
}

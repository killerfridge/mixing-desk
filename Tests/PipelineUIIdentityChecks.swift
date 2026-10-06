import AppKit
import SwiftUI
import DeskModels

@main @MainActor enum PipelineChecks {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MixingDesk-Pipeline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = DeskStore(startsMonitoring: false, supportDirectory: temporary)
        verifyConveniences(support: temporary.appendingPathComponent("Conveniences"))
        verifyLevelControls(support: temporary.appendingPathComponent("Levels"))
        verifyAppearance(support: temporary.appendingPathComponent("Appearance"))
        store.showingSetupGuide = false
        let initial = store.session
        store.savePipelinePositions([PipelineNodeID(.strip, initial.strips[0].id).key: PipelinePosition(x: 190, y: 140)])
        precondition(store.audioConfigurationUpdates == 0 && store.session.audioSession == initial)
        store.addOutput("offline")
        precondition(store.audioConfigurationUpdates == 0 && store.session.routes.isEmpty && !store.wantsRunning)
        store.undoRouting(); store.redoRouting()
        precondition(store.audioConfigurationUpdates == 0)
        let source = PipelineNodeID(.strip, initial.strips[0].id), bus = initial.buses[0].id
        let originalSend = store.session.sends(from: source).first { $0.busID == bus }!
        store.trackRoutingGesture(true, name: "Test gain drag")
        for gain in [-2.0,-4,-6] { store.setSend(from: source, to: bus, value: Send(busID: bus, gainDB: gain)) }
        precondition(store.session.sends(from: source).first { $0.busID == bus } == originalSend && store.audioConfigurationUpdates == 0, "Dragging must not commit partial routing")
        store.trackRoutingGesture(false, name: "Test gain drag")
        precondition(store.routingHistory.undoName == "Test gain drag")
        store.edit { $0.strips[0].faderDB = -18; $0.strips[0].inserts = [.equalizer()] }
        store.undoRouting()
        precondition(store.session.sends(from: source).first { $0.busID == bus } == originalSend)
        precondition(store.session.strips[0].faderDB == -18 && store.session.strips[0].inserts.count == 1)
        let saved = store.session
        precondition(!store.setSend(from: PipelineNodeID(.bus, bus), to: bus, value: Send(busID: bus)))
        precondition(store.session == saved)
        store.error = nil
        store.devices = [Device(["uid": "mono", "name": "Mono", "outputs": ["Mono"], "supports48k": true])]
        var route = OutputRoute(sourceKind: "strip", sourceID: source.rawID, destinationUID: "mono", channels: [0])
        precondition(store.saveRoute(route))
        route.channels = [1]; precondition(!store.saveRoute(route)); store.error = nil
        store.devices = []; route.channels = [0]; route.gainDB = -3
        precondition(store.saveRoute(route), "Offline existing route level should remain editable")
        route.channels = [1]; precondition(!store.saveRoute(route)); store.error = nil
        store.devices = [Device(["uid": "mono", "name": "Mono", "outputs": ["Mono"], "supports48k": true])]
        store.chooseMonitor("mono")
        precondition(store.session.monitorDeviceUID == "mono" && !store.wantsRunning)
        store.undoRouting(); precondition(store.session.monitorDeviceUID.isEmpty)
        let beforeRemove = store.session
        store.removePipelineNode(PipelineNodeID(.strip, source.rawID))
        precondition(!store.session.routes.contains { $0.sourceID == source.rawID })
        store.undoRouting(); precondition(store.session == beforeRemove)
        store.redoRouting(); precondition(!store.session.strips.contains { $0.id == source.rawID })
        store.undoRouting()
        store.removePipelineNode(PipelineNodeID(.bus, bus))
        precondition(store.session == beforeRemove && store.error?.contains("Monitor") == true)
        store.error = nil
        let pinned = store.session.pipelineLayout
        store.devices = []; store.devices = [Device(["uid": "mono", "name": "Renamed mono", "outputs": ["Mono"], "supports48k": true])]
        precondition(store.session.pipelineLayout == pinned, "Discovery must not rearrange blocks")
        store.savePreset("Pipeline round trip")
        let preset = temporary.appendingPathComponent("Presets/Pipeline round trip.json")
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: preset.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        let presetSession = try Session.decode(Data(contentsOf: preset))
        precondition(presetSession.pipelineLayout == pinned)
        let exported = temporary.appendingPathComponent("Export.json")
        try store.session.data().write(to: exported)
        let exportSession = try Session.decode(Data(contentsOf: exported))
        precondition(exportSession.pipelineLayout == pinned)
        store.saveLastSession()
        let reload = DeskStore(startsMonitoring: false, supportDirectory: temporary)
        precondition(reload.session == store.session && reload.session.pipelineLayout != nil)
        let url = temporary.appendingPathComponent("Last Session.json")
        store.load(url); precondition(store.routingHistory.undoName == nil && store.routingHistory.redoName == nil)
        let loaded = store.session
        var badSource = loaded.strips[0]
        badSource.source.deviceUID = "mono"; badSource.source.channels = [0]
        precondition(!store.configureChannel(badSource), "An output-only device cannot be an input")
        precondition(store.session == loaded); store.error = nil
        badSource.source.kind = "application"; badSource.source.channels = [2]
        precondition(!store.configureChannel(badSource)); store.error = nil
        store.removePipelineNode(PipelineNodeID(.output, "mono"))
        precondition(!store.session.routes.contains { $0.destinationUID == "mono" } && store.devices.count == 1)
        store.undoRouting(); precondition(store.session == loaded)
        let removedBus = loaded.buses[1].id
        store.removePipelineNode(PipelineNodeID(.bus, removedBus))
        precondition(!store.session.strips.flatMap(\.sends).contains { $0.busID == removedBus })
        store.undoRouting(); precondition(store.session == loaded)
        let lastUndo = store.routingHistory.undoName
        precondition(!store.routeEdit("Too many outputs", { s in
            s.routes = (0..<513).map { _ in OutputRoute(sourceID: bus, destinationUID: "mono", channels: [0]) }
        }))
        precondition(store.session == loaded && store.routingHistory.undoName == lastUndo)
        store.error = nil
        store.addStrip(withDisabledSends: false)
        precondition(store.session.strips.last!.sends.isEmpty)
        let addedSource = PipelineNodeID(.strip, store.session.strips.last!.id)
        store.setSend(from: addedSource, to: bus, value: Send(busID: bus))
        precondition(store.session.sends(from: addedSource) == [Send(busID: bus)])
        store.undoRouting(); store.undoRouting(); precondition(store.session == loaded)
        var pluginSession = Session.starter()
        pluginSession.strips[0].inserts = [.audioUnit(identifier: "61756678:68706173:6170706c", name: "Apple AUHipass")]
        let pluginStore = DeskStore(initialSession: pluginSession, startsMonitoring: false, supportDirectory: temporary.appendingPathComponent("Plugin"))
        try pluginStore.audio.updateSession(pluginSession.dictionary())
        let pluginNode = PipelineNodeID(.strip, pluginSession.strips[0].id)
        pluginStore.removePipelineNode(pluginNode)
        let captureDeadline = Date().addingTimeInterval(5)
        while pluginStore.session.strips.contains(where: { $0.id == pluginNode.rawID }), Date() < captureDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        precondition(!pluginStore.session.strips.contains { $0.id == pluginNode.rawID })
        pluginStore.undoRouting()
        precondition(pluginStore.session.strips[0].inserts[0].state != nil, "Node removal must snapshot native AU state before undo restores it")
        print("PASS: real store routing transactions, one-action gain drag, presentation isolation, rejection, offline mapping, monitoring and persistence")
        if CommandLine.arguments.contains("--interactive") {
            PipelineFixture.populate(store)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1180, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Pipeline UI Test — isolated session, no audio IO"
            window.minSize = NSSize(width: 800, height: 520)
            let suite = "MixingDesk-Pipeline-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            window.contentView = NSHostingView(rootView: ContentView(initialPage: "Pipeline").environmentObject(store).defaultAppStorage(defaults))
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
            app.run()
        }
    }

    static func verifyAppearance(support: URL) {
        let store = DeskStore(startsMonitoring: false, supportDirectory: support)
        store.showingSetupGuide = false
        let suite = "MixingDesk-Appearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let hosting = NSHostingView(rootView: ContentView(initialPage: "Pipeline").environmentObject(store).defaultAppStorage(defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 520), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting; window.orderBack(nil)
        let original = store.session
        for mode in [DeskAppearance.light, .dark, .light, .system] {
            defaults.set(mode.rawValue, forKey: "deskAppearance")
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            hosting.layoutSubtreeIfNeeded()
            let expected = mode == .system ? NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) : mode == .light ? .aqua : .darkAqua
            precondition(hosting.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "Appearance must switch in an existing window and return to System")
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let brightness = bitmap.colorAt(x: 1, y: 1)!.usingColorSpace(.sRGB)!.redComponent
            precondition(expected == .aqua ? brightness > 0.9 : brightness < 0.2, "Custom surfaces must follow the native appearance")
        }
        precondition(store.session == original && store.audioConfigurationUpdates == 0, "Appearance must leave audio and session settings intact")
        window.orderOut(nil)
        print("PASS: live Light/Dark/System switching, adaptive surfaces and audio isolation")
    }

    static func verifyConveniences(support: URL) {
        let store = DeskStore(startsMonitoring: false, supportDirectory: support)
        store.edit { s in s.strips[0].solo = true; s.strips[2].solo = true; s.strips[1].muted = true; s.strips[0].faderDB = -6.25; s.strips[0].inserts = [.equalizer()] }
        var expected = store.session
        for i in expected.strips.indices { expected.strips[i].solo = false }
        var changes = 0
        let token = store.objectWillChange.sink { changes += 1 }
        let updates = store.audioConfigurationUpdates
        store.clearAllSolos()
        precondition(changes == 1 && store.audioConfigurationUpdates == updates+1 && store.session == expected, "Clear All Solos must be one update preserving every other setting")
        store.clearAllSolos(); precondition(changes == 1)
        withExtendedLifetime(token) {}

        let owner = store.session.strips[0].id
        store.meters.update(MeterSnapshot(strips: [MeterValue(["id": owner, "heldL": 0.7, "reductionDB": 6])]))
        store.session.strips.reverse()
        precondition(store.meters.value.meter(ownerID: owner, isBus: false).heldL == 0.7, "Telemetry lookup must use stable owner IDs across reorderings")
        precondition(store.meters.value.meter(ownerID: store.session.strips[0].id, isBus: false).heldL == 0)

        var level = -6.25
        let editor = NumericLevelEditor(value: Binding(get: { level }, set: { level = $0 }), range: -24...24, label: "Precise test")
        let coordinator = editor.makeCoordinator()
        let field = NSTextField()
        field.delegate = coordinator
        func entry(_ text: String, cancel: Bool = false) {
            coordinator.editing = true; field.stringValue = text
            coordinator.finish(field, cancel: cancel)
        }
        entry("-12.345"); precondition(level == -12.345)
        for text in ["", "nonsense", "nan", "inf", "-inf", "1e1000", "24.001", "-24.001"] { entry(text); precondition(level == -12.345, "Invalid numeric input must not change audio") }
        entry("-3", cancel: true); precondition(level == -12.345)
        entry("−2.75"); precondition(level == -2.75)
        coordinator.editing = true; field.stringValue = "-1.125"
        coordinator.controlTextDidEndEditing(Notification(name: NSText.didEndEditingNotification, object: field))
        precondition(level == -1.125, "Focus loss must commit valid numeric input")
        entry("-24"); precondition(level == -24)
        entry("24"); precondition(level == 24)

        let surface = FaderMouseSurface.MouseView(frame: NSRect(x: 0, y: 0, width: 70, height: 200))
        surface.currentPosition = { 90 }
        var position: CGFloat = 90, resets = 0
        surface.onPosition = { next, _ in position = next }; surface.onReset = { resets += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 220), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView!.addSubview(surface)
        func event(_ type: NSEvent.EventType, x: CGFloat = 0, y: CGFloat, shift: Bool = false, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: shift ? [.shift] : [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        surface.mouseDown(with: event(.leftMouseDown, y: 170, shift: true))
        precondition(position == 90, "Shift-down must anchor to the value without a jump")
        surface.mouseDragged(with: event(.leftMouseDragged, y: 120, shift: true))
        precondition(abs(position-95) < 0.0001, "Shift fader motion must have one-tenth sensitivity")
        surface.mouseUp(with: event(.leftMouseUp, y: 120))
        surface.mouseDown(with: event(.leftMouseDown, y: 120, clicks: 2)); precondition(resets == 1)

        let slider = ResettableSlider.ResetSlider(frame: NSRect(x: 0, y: 0, width: 200, height: 18))
        slider.minValue = -90; slider.maxValue = 12; slider.doubleValue = -6
        var tracking: [Bool] = []
        slider.trackingChanged = { tracking.append($0) }
        window.contentView!.addSubview(slider)
        NSApp.postEvent(event(.leftMouseDragged, x: 150, y: 10, shift: true), atStart: false)
        NSApp.postEvent(event(.leftMouseUp, x: 150, y: 10, shift: true), atStart: false)
        slider.mouseDown(with: event(.leftMouseDown, x: 100, y: 10, shift: true))
        let travel = max(1, slider.bounds.width - (slider.cell as! NSSliderCell).knobThickness)
        precondition(abs(slider.doubleValue - (-6 + Double(50/travel)*102*0.1)) < 0.0001)
        precondition(tracking == [true, false], "Fine slider tracking must preserve one routing gesture begin/end pair")
        window.orderOut(nil)
        print("PASS: atomic solo clearing, owner-keyed telemetry, numeric validation/focus loss/cancel/precision, anchored Shift-fader and Shift-slider tracking")
    }

    static func verifyLevelControls(support: URL) {
        let store = DeskStore(startsMonitoring: false, supportDirectory: support)
        let channelID = store.session.strips[0].id, busID = store.session.buses[0].id
        let original = store.session
        for node in [PipelineNodeID(.strip, channelID), PipelineNodeID(.bus, busID)] {
            let hosting = NSHostingView(rootView: PipelineLevelControls(node: node, name: "Test signal").environmentObject(store))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 212, height: 64), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting; window.orderBack(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            func slider(in view: NSView) -> ResettableSlider.ResetSlider? {
                if let control = view as? ResettableSlider.ResetSlider { return control }
                return view.subviews.lazy.compactMap { slider(in: $0) }.first
            }
            guard let control = slider(in: hosting), let action = control.action else { preconditionFailure("Pipeline must expose a native level slider") }
            func setLevel(_ value: Double) { control.doubleValue = value; control.sendAction(action, to: control.target) }
            func level() -> Double {
                node.kind == .strip ? store.session.strips.first { $0.id == node.rawID }!.faderDB : store.session.buses.first { $0.id == node.rawID }!.gainDB
            }
            @MainActor func numeric(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.accessibilityLabel() == "Test signal level" { return field }
                return view.subviews.lazy.compactMap { numeric(in: $0) }.first
            }
            guard let field = numeric(in: hosting), let delegate = field.delegate as? NumericLevelEditor.Coordinator else { preconditionFailure("Pipeline must share the native numeric editor") }
            window.makeKeyAndOrderFront(nil)
            func begin(_ text: String) -> NSTextView {
                precondition(window.makeFirstResponder(field))
                guard let editor = field.currentEditor() as? NSTextView else { preconditionFailure("Numeric entry must focus") }
                editor.string = text; return editor
            }
            let submitted = begin("-7.125")
            precondition(delegate.control(field, textView: submitted, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            precondition(level() == -7.125 && field.stringValue == NumericLevelEditor.display(-7.125), "Enter must commit exact numeric input and restore the readout")
            let cancelled = begin("-9")
            precondition(delegate.control(field, textView: cancelled, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            precondition(level() == -7.125, "Escape must leave audio unchanged")
            _ = begin("-8.25"); window.makeFirstResponder(nil)
            precondition(level() == -8.25, "Native focus loss must commit")
            _ = begin("nan"); window.makeFirstResponder(nil); precondition(level() == -8.25)
            let updates = store.audioConfigurationUpdates
            setLevel(-18.5)
            precondition(level() == -18.5 && store.audioConfigurationUpdates == updates + 1, "Pipeline slider must update the shared audio session immediately")
            setLevel(-90); precondition(level() == -90)
            setLevel(12); precondition(level() == 12)
            let reset = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            control.mouseDown(with: reset); precondition(level() == 0, "Double-click must reset to unity")
            store.edit { session in
                if node.kind == .strip { session.strips.reverse() } else { session.buses.reverse() }
            }
            setLevel(-6); precondition(level() == -6, "An existing control must retain node identity after reordering")
            precondition(store.session.routes == original.routes && store.session.strips.flatMap(\.sends) == original.strips.reversed().flatMap(\.sends))
            precondition(store.routingHistory.undoName == nil && store.session.pipelineLayout == original.pipelineLayout)
            window.orderOut(nil)
        }
        store.saveLastSession()
        let restored = DeskStore(startsMonitoring: false, supportDirectory: support)
        precondition(restored.session.strips.first { $0.id == channelID }?.faderDB == -6 && restored.session.buses.first { $0.id == busID }?.gainDB == -6)
        print("PASS: native pipeline channel/bus sliders, live updates, limits, double-click reset, stable identity and persistence")
    }
}

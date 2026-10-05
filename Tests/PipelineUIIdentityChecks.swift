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
        print("PASS: real store routing transactions, one-action gain drag, presentation isolation, rejection, offline mapping, monitoring and persistence")
        if CommandLine.arguments.contains("--interactive") {
            PipelineFixture.populate(store)
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1180, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Pipeline UI Test — isolated session, no audio IO"
            window.minSize = NSSize(width: 800, height: 520)
            window.contentView = NSHostingView(rootView: ContentView(initialPage: "Pipeline").environmentObject(store).preferredColorScheme(.dark))
            window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
            app.run()
        }
    }
}

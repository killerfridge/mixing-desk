import Foundation
import DeskModels

@MainActor enum PipelineFixture {
    static func populate(_ store: DeskStore, dense: Bool = false) {
        var session = Session.starter()
        session.strips[0].source.deviceUID = "fixture.interface"
        session.strips[0].inserts = [.equalizer()]
        session.strips[1].name = "Music"; session.strips[1].source.bundleID = "fixture.music"
        session.strips[2].source.bundleID = "fixture.call"
        session.strips[2].sends.removeAll { $0.busID == session.buses[1].id }
        session.monitorDeviceUID = "fixture.headphones"
        session.routes = [OutputRoute(sourceID: session.buses[0].id, destinationUID: "fixture.headphones"),
                          OutputRoute(sourceID: session.buses[1].id, destinationUID: "local.mixingdesk.virtual.fixture"),
                          OutputRoute(sourceID: session.buses[2].id, destinationUID: "fixture.offline")]
        store.devices = [Device(["uid": "fixture.interface", "name": "USB Audio Interface", "inputs": ["Microphone", "Instrument"], "outputs": ["Left", "Right"], "supports48k": true]),
                         Device(["uid": "fixture.headphones", "name": "Headphones", "outputs": ["Left", "Right"], "supports48k": true]),
                         Device(["uid": "local.mixingdesk.virtual.fixture", "name": "Call Microphone", "outputs": ["Left", "Right"], "supports48k": true])]
        store.apps = [AudioApplication(bundleID: "fixture.music", name: "Music Player", processIDs: []), AudioApplication(bundleID: "fixture.call", name: "Call App", processIDs: [])]
        if dense {
            while session.buses.count < 16 { session.buses.append(Bus(name: "Mix \(session.buses.count+1)")) }
            while session.strips.count < 64 {
                var strip = ChannelStrip(name: "Source \(session.strips.count+1)")
                strip.sends = session.buses.map { Send(busID: $0.id, gainDB: session.strips.count % 2 == 0 ? -12 : -90) }
                session.strips.append(strip)
            }
            for index in 0..<500 { session.routes.append(OutputRoute(sourceKind: "strip", sourceID: session.strips[index % 64].id, destinationUID: "fixture.offline", channels: [index % 16])) }
        }
        store.session = session; store.showingSetupGuide = false
        store.running = false; store.wantsRunning = false
    }
}

import AppKit
import SwiftUI
import DeskModels

@main struct AppScreenshots {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MixingDesk-Documentation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = DeskStore(supportDirectory: temporary, discover: false)
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
        let restored = DeskStore(supportDirectory: temporary, discover: false)
        precondition(!restored.showingSetupGuide && restored.session == saved && !restored.wantsRunning)

        let mono = Device(["uid": "mono", "name": "Mono output", "outputs": ["Output"], "supports48k": true])
        store.devices = [mono]; store.chooseMonitor("mono")
        precondition(store.session.routes.last?.channels == [0])
        store.devices = []; store.session = .starter(); store.showingSetupGuide = false
        store.driverStatus = DriverStatus(["state": "missing", "message": "Optional driver not installed. Run the Mixing Desk installer and select Mixing Desk Audio if you need virtual microphone or recording devices."])

        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try render(ContentView().environmentObject(store), size: NSSize(width: 1180, height: 740), to: directory.appendingPathComponent("desk.png"))
        try render(SetupGuide().environmentObject(store), size: NSSize(width: 706, height: 626), to: directory.appendingPathComponent("setup.png"))
        print("PASS: first-run setup, saved-session preservation, mono output patch; rendered actual SwiftUI desk/setup views without hardware IO or personal session data")
    }

    @MainActor static func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        window.orderOut(nil)
    }
}

import AppKit
import Combine
import SwiftUI
import DeskModels
@preconcurrency import DeskAudio

// Exercises the real UI status path without opening audio devices, starting IO,
// or reading/writing the user's session. --benchmark also opens disposable desk
// and AU windows, replaying moving meters at the production 30 Hz rate.
@main @MainActor enum UIStatusTests {
    static func status(_ tick: Int = 0) -> [String: Any] {
        let level = Double(tick % 100) / 100
        let meter: [String: Any] = ["peakL": level, "peakR": level * 0.8,
                                   "rmsL": level * 0.5, "rmsR": level * 0.4, "clip": false]
        return ["running": true, "strips": Array(repeating: meter, count: 4),
                "buses": Array(repeating: meter, count: 4), "load": level * 0.2,
                "underruns": 0, "bufferFrames": 128, "estimatedLatencyMs": 5.3,
                "offline": ["Offline test source"],
                "plugins": [["id": "test", "latencyFrames": 32, "error": ""]],
                "synchronization": [["uid": "test", "name": "Test clock", "driftCorrection": 0]]]
    }
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let store = DeskStore(initialSession: .starter(), startsMonitoring: false)
        store.wantsRunning = true
        store.receiveStatus(status())
        var deskChanges = 0
        let observation = store.objectWillChange.sink { deskChanges += 1 }

        if !CommandLine.arguments.contains("--benchmark") {
            var meterChanges = 0, loadChanges = 0
            let meterObservation = store.meters.objectWillChange.sink { meterChanges += 1 }
            let loadObservation = store.engineLoad.objectWillChange.sink { loadChanges += 1 }
            for tick in 1...300 { store.receiveStatus(status(tick)) }
            precondition(deskChanges == 0, "Meter polling invalidated the desk or app scenes")
            precondition(meterChanges == 300 && loadChanges == 300, "Live readings stopped updating")
            store.receiveStatus(status(300))
            precondition(meterChanges == 300 && loadChanges == 300, "Unchanged readings were republished")
            var changed = status(300)
            changed["plugins"] = [["id": "test", "latencyFrames": 64, "error": "Test failure"]]
            changed["offline"] = ["Another offline source"]
            changed["bufferFrames"] = 256
            changed["estimatedLatencyMs"] = 8.2
            changed["synchronization"] = [["uid": "new", "name": "New clock", "driftCorrection": 1]]
            store.receiveStatus(changed)
            precondition(deskChanges == 5, "Actual status changes were lost")
            precondition(store.actualFrames == 256 && store.estimatedLatency == 8.2)
            precondition(store.pluginStatus["test"]?["latencyFrames"] as? Int == 64)
            precondition(store.pluginStatus["test"]?["error"] as? String == "Test failure")
            precondition(store.clockMembers.first?.corrected == true)
            store.receiveStatus(changed)
            precondition(deskChanges == 5, "Unchanged status was republished")
            changed["running"] = false
            store.receiveStatus(changed)
            precondition(!store.running && store.meters.value.strips.isEmpty && store.meters.value.buses.isEmpty)
            precondition(deskChanges == 6, "Stop transition was lost")
            withExtendedLifetime([observation, meterObservation, loadObservation]) {}
            print("PASS: 300 moving meter/load updates, no desk invalidations; unchanged status suppression; latency/errors/devices/stop transitions")
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            fputs("FAIL: UI benchmark exceeded 30 seconds\n", stderr)
            _exit(124)
        }
        app.finishLaunching()
        let desk = NSWindow(contentRect: NSRect(x: 30, y: 50, width: 1180, height: 740),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        desk.title = "Mixing Desk · UI performance test"
        desk.contentView = NSHostingView(rootView: ContentView().environmentObject(store).preferredColorScheme(.dark))
        desk.makeKeyAndOrderFront(nil)
        var plugin: PluginWindow?
        if let flag = CommandLine.arguments.firstIndex(of: "--au"), flag + 1 < CommandLine.arguments.count {
            var session = Session.starter()
            session.strips[0].inserts = [.audioUnit(identifier: CommandLine.arguments[flag + 1], name: "Benchmark AU")]
            try store.audio.updateSession(session.dictionary())
            guard let editor = store.audio.pluginEditor(session.strips[0].inserts[0].id), let view = editor.makeView() else {
                fatalError("Benchmark AU could not open")
            }
            plugin = PluginWindow(editor: editor, view: view)
            plugin?.showWindow(nil)
            plugin?.window?.makeKeyAndOrderFront(nil)
        }
        app.activate(ignoringOtherApps: true)
        var tick = 0, gaps: [Double] = []
        var last = ProcessInfo.processInfo.systemUptime
        var start = last, cpuStart = clock()
        let heartbeat = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            if tick > 60 { gaps.append((now - last) * 1000) }
            last = now
        }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { _ in MainActor.assumeIsolated {
            tick += 1
            store.receiveStatus(status(tick))
            if tick == 60 { start = ProcessInfo.processInfo.systemUptime; cpuStart = clock(); deskChanges = 0 }
            if tick == 360 {
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                let cpu = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
                let sorted = gaps.sorted()
                print(String(format: "UI BENCHMARK: ticks=300 deskNotifications=%d CPU=%.3fs elapsed=%.3fs CPU=%.1f%% heartbeatP95=%.2fms max=%.2fms", deskChanges, cpu, elapsed, cpu / elapsed * 100, sorted[sorted.count * 95 / 100], sorted.last ?? 0))
                app.stop(nil)
                NSEvent.startPeriodicEvents(afterDelay: 0, withPeriod: 0.01)
            }
        } }
        RunLoop.main.add(heartbeat, forMode: .common)
        RunLoop.main.add(timer, forMode: .common)
        app.run()
        timer.invalidate(); heartbeat.invalidate(); NSEvent.stopPeriodicEvents()
        plugin?.close(); desk.close()
        withExtendedLifetime([observation]) {}
        // Process exit follows AppKit teardown; no physical audio was started.
    }
}

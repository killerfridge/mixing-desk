import SwiftUI
import DeskModels
import DeskAudio

@main enum MixingDeskMain {
    static func main() {
        guard !MDAudioController.runPluginScannerCommand() else { return }
        MixingDeskApp.main()
    }
}
struct MixingDeskApp: App {
    @StateObject private var store = DeskStore()
    var body: some Scene {
        WindowGroup("Mixing Desk", id: "desk") {
            ContentView().environmentObject(store).frame(minWidth: 800, minHeight: 520)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Setup Guide…") { store.showingSetupGuide = true }.disabled(store.wantsRunning)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Session…", action: store.openSession).keyboardShortcut("o")
                Button("Export Session…", action: store.exportSession).keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appTermination) { Button("Quit Mixing Desk", action: store.quit).keyboardShortcut("q") }
        }
        MenuBarExtra("Mixing Desk", systemImage: "slider.vertical.3") { DeskMenu().environmentObject(store) }
    }
}
private struct DeskMenu: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.running ? "Mixing at 48 kHz" : "Audio stopped")
        Button("Show Mixing Desk") { openWindow(id: "desk"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.wantsRunning ? "Stop Audio" : "Start Audio", action: store.toggleAudio)
        Divider()
        Button("Quit Mixing Desk", action: store.quit)
    }
}

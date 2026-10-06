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
    @AppStorage("deskAppearance") private var appearance = DeskAppearance.system.rawValue
    var body: some Scene {
        WindowGroup("Mixing Desk", id: "desk") {
            ContentView().environmentObject(store).frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 740)
        .commands {
            CommandMenu("Desk") {
                Button("Clear All Solos", action: store.clearAllSolos).keyboardShortcut("l", modifiers: [.command, .shift]).disabled(store.soloCount == 0)
                Button("Reset All Meters", action: store.resetAllMeters)
                Toggle("Output Protection", isOn: Binding(get: { store.session.outputProtectionEnabled }, set: { enabled in store.edit { $0.outputProtectionEnabled = enabled } }))
            }
            CommandMenu("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(DeskAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
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
        Button("Clear All Solos", action: store.clearAllSolos).keyboardShortcut("l", modifiers: [.command, .shift]).disabled(store.soloCount == 0)
        Button("Reset All Meters", action: store.resetAllMeters)
        Divider()
        Button("Quit Mixing Desk", action: store.quit)
    }
}

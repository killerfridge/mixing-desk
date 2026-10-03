import SwiftUI
import AppKit
import DeskModels
@preconcurrency import DeskAudio

struct PluginChoice: Identifiable {
    var id: String { "\(format):\(identifier)" }
    let identifier: String
    let format: String
    var formatName: String { format == "vst3" ? "VST3" : "AUv2" }
    let name: String
    let manufacturer: String
    init(_ value: [String: Any]) {
        identifier = value["id"] as? String ?? ""
        format = value["format"] as? String ?? "au"
        name = value["name"] as? String ?? "Plugin"
        manufacturer = value["manufacturer"] as? String ?? ""
    }
}
struct PluginBrowser: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    var add: (PluginChoice) -> Void
    @State private var search = ""
    @State private var format = "all"
    private var matches: [PluginChoice] {
        store.plugins.filter { (format == "all" || $0.format == format) && (search.isEmpty || "\($0.name) \($0.manufacturer) \($0.formatName)".localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(title: "Plugins", subtitle: "Installed VST3 and AUv2 effects")
                Spacer()
                Button("Rescan") { store.scanPlugins() }.disabled(store.scanningPlugins)
                Button("Done") { dismiss() }
            }
            TextField("Search by plugin or manufacturer", text: $search).textFieldStyle(.roundedBorder)
            Picker("Format", selection: $format) { Text("All formats").tag("all"); Text("VST3").tag("vst3"); Text("AUv2").tag("au") }.pickerStyle(.segmented)
            if store.scanningPlugins { ProgressView("Scanning plugins…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if matches.isEmpty {
                ContentUnavailableView("No matching effects", systemImage: "puzzlepiece.extension", description: Text("Install an Apple Silicon VST3 or AUv2 effect with your plugin's installer, then rescan. Instruments, AUv3, and VST2 are not supported."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(matches) { plugin in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plugin.name).font(.system(size: 13, weight: .semibold))
                                    Text(plugin.manufacturer).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(plugin.formatName).font(.caption.monospaced()).foregroundStyle(.secondary)
                                Button("Add") { add(plugin); dismiss() }.accessibilityLabel("Add \(plugin.name)")
                            }.padding(12).background(DeskStyle.panel)
                        }
                    }
                }
            }
            Text("Neural DSP and native UADx effects use their existing licenses. UAD-2 effects also need compatible UA hardware.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width: 600, height: 500).background(DeskStyle.background)
            .onAppear { if store.plugins.isEmpty { store.scanPlugins() } }
    }
}

struct PluginInsertView: View {
    @EnvironmentObject var store: DeskStore
    @Binding var slot: InsertSlot
    private var status: [String: Any] { store.pluginStatus[slot.id] ?? [:] }
    private var failure: String { status["error"] as? String ?? "" }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(slot.displayName).font(.title2.bold())
                    Text("\(slot.formatName) effect").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Bypass", isOn: $slot.bypassed).toggleStyle(.switch).fixedSize()
            }
            Image(systemName: "puzzlepiece.extension").font(.system(size: 52)).foregroundStyle(DeskStyle.accent).frame(maxWidth: .infinity).padding(.vertical, 18)
            Button { store.openPluginEditor(slot.id) } label: {
                Label(slot.format == "vst3" ? "Open Parameter Editor" : "Open Plugin Editor", systemImage: "macwindow").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(store.loadingPlugin)
            if store.loadingPlugin { ProgressView("Loading plugin…") }
            if !failure.isEmpty { Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            HStack {
                if let frames = status["latencyFrames"] as? NSNumber {
                    Text(String(format: "Plugin latency: %.2f ms", frames.doubleValue / 48))
                } else { Text("Ready to load").foregroundStyle(.secondary) }
                Spacer()
                Button("Reload") { store.reloadPlugin(slot.id) }.disabled(store.loadingPlugin)
                if slot.format == "au" { Button("Import AU Preset…") { store.importAudioUnitPreset(slotID: slot.id) } }
            }.font(.caption)
            if slot.format == "vst3" { Text("VST3 effects use the desk’s parameter editor. Vendor VST3 windows are not available in this release.").font(.caption).foregroundStyle(.secondary) }
            Text("Settings are saved with your desk. Effects can add latency; parallel paths are not delay-compensated. If a plugin cannot load, its active output is silenced; bypass it to hear the dry signal.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, maxHeight: .infinity).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

@MainActor final class PluginWindow: NSWindowController, NSWindowDelegate {
    let editor: MDPluginEditor
    var didClose: (() -> Void)?
    init(editor: MDPluginEditor, view: NSView) {
        self.editor = editor
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1200, height: 800)
        let native = view.fittingSize
        let desired = NSSize(width: max(400, max(view.frame.width, native.width)), height: max(280, max(view.frame.height, native.height)))
        view.setFrameSize(desired)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: min(desired.width, screen.width - 80), height: min(desired.height, screen.height - 100))), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = editor.name
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.documentView = view
        window.contentView = scroll; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func windowWillClose(_ notification: Notification) { didClose?() }
}

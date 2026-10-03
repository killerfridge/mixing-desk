import SwiftUI
import AppKit
import AVFoundation
// Objective-C controller is confined to audioQueue after construction.
@preconcurrency import DeskAudio
import DeskModels
import UniformTypeIdentifiers

struct Device: Identifiable {
    var id: String { uid }; let uid: String; let name: String; let inputs: [String]; let outputs: [String]; let supports48k: Bool; let minBuffer: Int; let maxBuffer: Int
    init(_ d: [String: Any]) { uid = d["uid"] as? String ?? ""; name = d["name"] as? String ?? "Device"; inputs = d["inputs"] as? [String] ?? []; outputs = d["outputs"] as? [String] ?? []; supports48k = d["supports48k"] as? Bool ?? false; minBuffer = (d["minBuffer"] as? NSNumber)?.intValue ?? 32; maxBuffer = (d["maxBuffer"] as? NSNumber)?.intValue ?? 4096 }
}
struct AudioApplication: Identifiable { var id: String { bundleID }; let bundleID: String; let name: String; let processIDs: [Int] }
struct VirtualDevice: Identifiable { var id: String { uid }; let uid: String; var name: String; let channels: Int; let clients: Int }
struct ClockMember: Identifiable {
    var id: String { uid }; let uid: String; let name: String; let corrected: Bool
    init(_ data: [String: Any]) { uid = data["uid"] as? String ?? ""; name = data["name"] as? String ?? "Audio source"; corrected = (data["driftCorrection"] as? NSNumber)?.intValue == 1 }
}
struct MeterValue { var peakL: Float = 0; var peakR: Float = 0; var rmsL: Float = 0; var rmsR: Float = 0; var clip = false
    init(_ data: [String: Any] = [:]) { peakL = (data["peakL"] as? NSNumber)?.floatValue ?? 0; peakR = (data["peakR"] as? NSNumber)?.floatValue ?? 0; rmsL = (data["rmsL"] as? NSNumber)?.floatValue ?? 0; rmsR = (data["rmsR"] as? NSNumber)?.floatValue ?? 0; clip = data["clip"] as? Bool ?? false }
}
@MainActor final class DeskStore: ObservableObject {
    @Published var session: Session
    @Published var devices: [Device] = []
    @Published var apps: [AudioApplication] = []
    @Published var virtualDevices: [VirtualDevice] = []
    @Published var running = false
    @Published var wantsRunning = false
    @Published var configuring = false
    @Published var error: String?
    @Published var info = "Choose your USB inputs and headphone output to begin."
    @Published var stripMeters: [MeterValue] = []
    @Published var busMeters: [MeterValue] = []
    @Published var load: Double = 0
    @Published var underruns = 0
    @Published var actualFrames = 128
    @Published var estimatedLatency: Double = 0
    @Published var offline: [String] = []
    @Published var clockMembers: [ClockMember] = []
    @Published var presets: [URL] = []
    @Published var selectedStrip: String?
    @Published var plugins: [PluginChoice] = []
    @Published var scanningPlugins = false
    @Published var loadingPlugin = false
    @Published var pluginStatus: [String: [String: Any]] = [:]
    var maximumPluginLatencyMS: Double {
        func frames(_ slots: [InsertSlot]) -> Int { slots.filter { $0.isPlugin && !$0.bypassed }.reduce(0) { $0 + ((pluginStatus[$1.id]?["latencyFrames"] as? NSNumber)?.intValue ?? 0) } }
        return Double((session.strips.map { frames($0.inserts) }.max() ?? 0) + (session.buses.map { frames($0.inserts) }.max() ?? 0)) / 48
    }
    private var pluginStateEpoch = UUID()
    private var pluginWindows: [String: PluginWindow] = [:]
    let audio = MDAudioController()
    private let audioQueue = DispatchQueue(label: "local.mixingdesk.control", qos: .userInitiated)
    private var polling = false
    private var discovering = false
    private var operationID = UUID()
    private var meterTimer: Timer?
    private var discoveryTimer: Timer?
    private var pendingSave: DispatchWorkItem?
    private var preserveUnreadableSession = false
    private var lastApplied: Session
    private var suspended = false
    private var recovering = false
    private var requestingAudioAccess = false
    private var observers: [NSObjectProtocol] = []
    private let support: URL
    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Mixing Desk", isDirectory: true)
        let saved = support.appendingPathComponent("Last Session.json")
        let initial: Session
        do { if FileManager.default.fileExists(atPath: saved.path) { initial = try Session.decode(Data(contentsOf: saved)) } else { initial = .starter() } }
        catch { initial = .starter(); preserveUnreadableSession = true; self.error = "Last session could not be opened: \(error.localizedDescription). The original will be kept as a backup before saving a new session." }
        session = initial; lastApplied = initial
        refreshDiscovery(); refreshPresets()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshDiscovery(); if self?.pluginWindows.isEmpty == false { self?.capturePluginStates() } } }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.suspended = true; self?.stopAudio() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.suspended = false; self?.scheduleRestart() } })
    }
    func refreshDiscovery() {
        guard !discovering else { return }; discovering = true
        let audio = audio
        audioQueue.async { [weak self] in
            let deviceData = audio.devices(), appData = audio.applications(), virtualData = audio.virtualDevices()
            DispatchQueue.main.async {
                guard let self else { return }; self.discovering = false
                let selectedBundles = Set(self.session.strips.filter { $0.source.kind == "application" }.map { $0.source.bundleID })
                let previous = self.apps.filter { selectedBundles.contains($0.bundleID) }.map { "\($0.bundleID):\($0.processIDs)" }
                self.devices = deviceData.map(Device.init)
                self.apps = appData.map { AudioApplication(bundleID: $0["bundleID"] as? String ?? "", name: $0["name"] as? String ?? "App", processIDs: $0["processIDs"] as? [Int] ?? []) }
                self.virtualDevices = virtualData.map { VirtualDevice(uid: $0["uid"] as? String ?? "", name: $0["name"] as? String ?? "", channels: ($0["channels"] as? NSNumber)?.intValue ?? 2, clients: ($0["clients"] as? NSNumber)?.intValue ?? 0) }
                if self.wantsRunning && !self.suspended && !self.configuring {
                    if !self.devices.contains(where: { $0.uid == self.session.monitorDeviceUID }) { self.stopAudio(); self.info = "Monitor disconnected. Waiting for the same device; speakers will not be used." }
                    else if !self.running || previous != self.apps.filter({ selectedBundles.contains($0.bundleID) }).map({ "\($0.bundleID):\($0.processIDs)" }) { self.scheduleRestart() }
                }
            }
        }
    }
    func poll() {
        guard !polling, !configuring else { return }; polling = true
        let audio = audio
        audioQueue.async { [weak self] in
            let status = audio.status()
            DispatchQueue.main.async {
                guard let self else { return }; self.polling = false
                guard !self.configuring else { return }
                self.running = self.wantsRunning && (status["running"] as? Bool ?? false)
                self.stripMeters = (status["strips"] as? [[String: Any]] ?? []).map(MeterValue.init)
                self.busMeters = (status["buses"] as? [[String: Any]] ?? []).map(MeterValue.init)
                self.load = (status["load"] as? NSNumber)?.doubleValue ?? 0
                self.underruns = (status["underruns"] as? NSNumber)?.intValue ?? 0
                self.actualFrames = (status["bufferFrames"] as? NSNumber)?.intValue ?? 128
                self.estimatedLatency = (status["estimatedLatencyMs"] as? NSNumber)?.doubleValue ?? 0
                self.offline = status["offline"] as? [String] ?? []
                self.pluginStatus = Dictionary(uniqueKeysWithValues: (status["plugins"] as? [[String: Any]] ?? []).compactMap { item in (item["id"] as? String).map { ($0, item) } })
                self.clockMembers = (status["synchronization"] as? [[String: Any]] ?? []).map(ClockMember.init)
                if status["hardwareChanged"] as? Bool == true && self.wantsRunning { self.scheduleRestart() }
            }
        }
    }
    func scheduleRestart() {
        guard wantsRunning, !suspended, !recovering else { return }
        recovering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }; self.recovering = false
            guard self.wantsRunning, !self.suspended, self.devices.contains(where: { $0.uid == self.session.monitorDeviceUID }) else { return }
            self.startNow()
        }
    }
    func toggleAudio() {
        if wantsRunning { wantsRunning = false; stopAudio(); info = "Audio stopped."; return }
        guard !requestingAudioAccess else { return }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            wantsRunning = true; startNow(); return
        }
        requestingAudioAccess = true
        info = "Waiting for microphone access…"
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            requestingAudioAccess = false
            guard granted else { info = "Audio stopped: microphone access is unavailable."; error = "Microphone permission is required. Enable Mixing Desk in System Settings → Privacy & Security → Microphone."; return }
            wantsRunning = true; startNow()
        }
    }
    private func startNow() {
        do {
            let snapshot = try session.validated(), data = try snapshot.dictionary(), audio = audio
            configuring = true; let id = UUID(); operationID = id; watchOperation(id)
            info = "Configuring synchronized audio…"
            audioQueue.async { [weak self] in
                var failure: String?
                do { try audio.startSession(data) } catch { failure = error.localizedDescription }
                DispatchQueue.main.async {
                    guard let self, self.operationID == id else { return }; self.configuring = false
                    if let failure { self.running = false; self.wantsRunning = false; self.error = failure; return }
                    self.running = true; self.lastApplied = snapshot
                    self.info = snapshot.monitoringMode == "directGuitar" ? "Direct guitar: control headphone guitar level on the Quad Cortex." : "Mixer monitoring: disable the duplicate direct guitar path on the Quad Cortex."
                    self.apply()
                }
            }
        } catch { running = false; wantsRunning = false; self.error = error.localizedDescription }
    }
    private func watchOperation(_ id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now()+15) { [weak self] in
            guard let self, self.operationID == id, self.configuring else { return }
            self.info = "Core Audio is taking longer than expected. The interface remains available; quit and reopen if the device does not respond."
        }
    }
    private func stopAudio() {
        running = false; configuring = true; let id = UUID(); operationID = id; watchOperation(id)
        let audio = audio
        audioQueue.async { [weak self] in audio.stop(); DispatchQueue.main.async { guard let self, self.operationID == id else { return }; self.configuring = false } }
    }
    func apply() {
        guard session != lastApplied else { return }
        do {
            _ = try session.validated()
            let currentIDs = Set((session.strips.flatMap(\.inserts) + session.buses.flatMap(\.inserts)).map(\.id))
            for id in Array(pluginWindows.keys) where !currentIDs.contains(id) { pluginWindows[id]?.didClose = nil; pluginWindows[id]?.close(); pluginWindows.removeValue(forKey: id) }
            if session.strips.map(\.source) != lastApplied.strips.map(\.source) || session.strips.map(\.solo) != lastApplied.strips.map(\.solo) || session.strips.map(\.role) != lastApplied.strips.map(\.role) || session.buses.map(\.excludedStripID) != lastApplied.buses.map(\.excludedStripID) || session.monitoringMode != lastApplied.monitoringMode { pluginStateEpoch = UUID(); closePluginWindows() }
            let topologyChanged = session.monitorDeviceUID != lastApplied.monitorDeviceUID || session.bufferFrames != lastApplied.bufferFrames || session.strips.map(\.source) != lastApplied.strips.map(\.source) || Set(session.routes.map(\.destinationUID)) != Set(lastApplied.routes.map(\.destinationUID))
            if !configuring {
                if topologyChanged && running { startNow() }
                else {
                    let data = try session.dictionary(), audio = audio
                    audioQueue.async { [weak self] in do { try audio.updateSession(data) } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.error = message } } }
                }
            }
            lastApplied = session
            pendingSave?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.saveLastSession() }; pendingSave = work; DispatchQueue.main.asyncAfter(deadline: .now()+0.5, execute: work)
        } catch { self.error = error.localizedDescription; session = lastApplied }
    }
    func edit(_ change: (inout Session) -> Void) { change(&session); apply() }
    func chooseMonitor(_ uid: String) {
        edit { s in
            let old = s.monitorDeviceUID; s.monitorDeviceUID = uid
            if let bus = s.buses.first(where: { $0.kind == "monitor" }) {
                s.routes.removeAll { $0.sourceKind == "bus" && $0.sourceID == bus.id && $0.destinationUID == old }
                if !uid.isEmpty { s.routes.append(OutputRoute(sourceID: bus.id, destinationUID: uid)) }
            }
        }
    }
    func addStrip() { guard session.strips.count < 64 else { return }; edit { s in var strip = ChannelStrip(name: "Channel \(s.strips.count + 1)"); strip.sends = s.buses.map { Send(busID: $0.id, gainDB: -90, preFader: $0.kind == "monitor") }; s.strips.append(strip) } }
    func addBus() { edit { $0.buses.append(Bus(name: "Bus \($0.buses.count + 1)")) } }
    func sourceName(_ source: SourceBinding) -> String {
        if source.kind == "application" { return apps.first { $0.bundleID == source.bundleID }?.name ?? (source.bundleID.isEmpty ? "Choose application" : "\(source.bundleID) · offline") }
        return devices.first { $0.uid == source.deviceUID }?.name ?? (source.deviceUID.isEmpty ? "Choose input" : "Input offline")
    }
    func sourceOnline(_ source: SourceBinding) -> Bool { source.kind == "application" ? apps.contains { $0.bundleID == source.bundleID } : devices.contains { $0.uid == source.deviceUID } }
    func meterForStrip(_ id: String) -> MeterValue { guard running, let i = session.strips.firstIndex(where: { $0.id == id }), i < stripMeters.count else { return MeterValue() }; return stripMeters[i] }
    func meterForBus(_ id: String) -> MeterValue { guard running, let i = session.buses.firstIndex(where: { $0.id == id }), i < busMeters.count else { return MeterValue() }; return busMeters[i] }
    func scanPlugins() {
        guard !scanningPlugins else { return }; scanningPlugins = true
        audioQueue.async { [weak self] in
            let choices = MDAudioController.availablePlugins().map(PluginChoice.init)
            DispatchQueue.main.async { self?.plugins = choices; self?.scanningPlugins = false }
        }
    }
    func capturePluginStates(completion: (() -> Void)? = nil) {
        let audio = audio
        let epoch = pluginStateEpoch
        let requested = Dictionary(uniqueKeysWithValues: (session.strips.flatMap(\.inserts) + session.buses.flatMap(\.inserts)).map { ($0.id, $0) })
        audioQueue.async { [weak self] in
            let states = audio.pluginStates()
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.pluginStateEpoch == epoch else { completion?(); return }
                func merge(_ value: inout Session) {
                    for i in value.strips.indices { for j in value.strips[i].inserts.indices {
                        let slot = value.strips[i].inserts[j]
                        if slot.isPlugin, slot.state == requested[slot.id]?.state, slot.identifier == requested[slot.id]?.identifier, slot.format == requested[slot.id]?.format, let state = states[slot.id] { value.strips[i].inserts[j].state = state }
                    } }
                    for i in value.buses.indices { for j in value.buses[i].inserts.indices {
                        let slot = value.buses[i].inserts[j]
                        if slot.isPlugin, slot.state == requested[slot.id]?.state, slot.identifier == requested[slot.id]?.identifier, slot.format == requested[slot.id]?.format, let state = states[slot.id] { value.buses[i].inserts[j].state = state }
                    } }
                }
                var next = self.session; merge(&next)
                if next != self.session { merge(&self.lastApplied); self.session = next; self.saveLastSession() }
                completion?()
            }
        }
    }
    func openPluginEditor(_ insertID: String) {
        if let existing = pluginWindows[insertID] { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        guard !loadingPlugin else { return }
        do {
            let data = try session.dictionary(), audio = audio
            let epoch = pluginStateEpoch
            loadingPlugin = true
            audioQueue.async { [weak self] in
                var editor: MDPluginEditor?, failure: String?
                do { try audio.updateSession(data); editor = audio.pluginEditor(insertID) }
                catch { failure = error.localizedDescription }
                DispatchQueue.main.async {
                    guard let self else { return }; self.loadingPlugin = false
                    guard self.pluginStateEpoch == epoch, (self.session.strips.flatMap(\.inserts) + self.session.buses.flatMap(\.inserts)).contains(where: { $0.id == insertID }) else { return }
                    guard let editor, let view = editor.makeView() else {
                        self.error = failure ?? "This plugin could not open. Check its license, installation, and the insert's status."; return
                    }
                    let window = PluginWindow(editor: editor, view: view)
                    window.didClose = { [weak self] in self?.pluginWindows.removeValue(forKey: insertID); self?.capturePluginStates() }
                    self.pluginWindows[insertID] = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil)
                    self.capturePluginStates()
                }
            }
        } catch { self.error = error.localizedDescription }
    }
    func reloadPlugin(_ insertID: String) {
        pluginStateEpoch = UUID(); closePluginWindows()
        do {
            let snapshot = try session.dictionary(), audio = audio
            loadingPlugin = true
            audioQueue.async { [weak self] in
                audio.reloadPlugin(insertID)
                var failure: String?
                do { try audio.updateSession(snapshot) } catch { failure = error.localizedDescription }
                DispatchQueue.main.async { self?.loadingPlugin = false; if let failure { self?.error = failure } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func closePluginWindows() {
        for window in pluginWindows.values { window.didClose = nil; window.close() }
        pluginWindows.removeAll()
    }
    func importAudioUnitPreset(slotID: String) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "aupreset") ?? .propertyList]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count <= 16 * 1024 * 1024, let preset = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let type = preset["type"] as? NSNumber, let subtype = preset["subtype"] as? NSNumber, let maker = preset["manufacturer"] as? NSNumber
            else { throw SessionError.invalid("This is not an Audio Unit preset.") }
            let identifier = String(format: "%08x:%08x:%08x", type.uint32Value, subtype.uint32Value, maker.uint32Value)
            let slot = (session.strips.flatMap(\.inserts) + session.buses.flatMap(\.inserts)).first { $0.id == slotID }
            guard slot?.identifier == identifier else { throw SessionError.invalid("This preset belongs to a different Audio Unit.") }
            pluginStateEpoch = UUID(); closePluginWindows()
            edit { s in
                for i in s.strips.indices { for j in s.strips[i].inserts.indices where s.strips[i].inserts[j].id == slotID { s.strips[i].inserts[j].state = data } }
                for i in s.buses.indices { for j in s.buses[i].inserts.indices where s.buses[i].inserts[j].id == slotID { s.buses[i].inserts[j].state = data } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func clearClips() { let audio = audio; audioQueue.async { audio.clearClips() } }
    func createDevice(_ name: String, channels: Int) { let audio = audio; audioQueue.async { [weak self] in do { try audio.createVirtualDevice(name, channels: channels); DispatchQueue.main.async { self?.refreshDiscovery() } } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.error = message } } } }
    func renameDevice(_ device: VirtualDevice, name: String) { let audio = audio; audioQueue.async { [weak self] in do { try audio.renameVirtualDevice(device.uid, name: name); DispatchQueue.main.async { self?.refreshDiscovery() } } catch { let message = error.localizedDescription; DispatchQueue.main.async { self?.error = message } } } }
    func deleteDevice(_ device: VirtualDevice) {
        let restart = running; stopAudio(); let audio = audio
        audioQueue.async { [weak self] in
            var failure: String?; do { try audio.deleteVirtualDevice(device.uid) } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { guard let self else { return }; if let failure { self.error = failure }; self.refreshDiscovery(); if restart { self.startNow() } }
        }
    }
    func saveLastSession() {
        do {
            let data = try session.data(), destination = support.appendingPathComponent("Last Session.json")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            if preserveUnreadableSession {
                try FileManager.default.copyItem(at: destination, to: support.appendingPathComponent("Unreadable Session \(UUID().uuidString).json"))
                preserveUnreadableSession = false
            }
            try data.write(to: destination, options: .atomic)
        }
        catch { self.error = "Session save failed: \(error.localizedDescription)" }
    }
    func openSession() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL) { do { let next = try Session.decode(Data(contentsOf: url)); pluginStateEpoch = UUID(); closePluginWindows(); wantsRunning = false; stopAudio(); let audio = audio; audioQueue.async { audio.unloadPlugins() }; session = next; lastApplied = next; saveLastSession() } catch { self.error = error.localizedDescription } }
    func exportSession() { capturePluginStates { self.exportSessionSnapshot() } }
    private func exportSessionSnapshot() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "\(session.name).json"
        if panel.runModal() == .OK, let url = panel.url { do { try session.data().write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } }
    }
    func savePreset(_ name: String) { capturePluginStates { self.savePresetSnapshot(name) } }
    private func savePresetSnapshot(_ name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let folder = support.appendingPathComponent("Presets", isDirectory: true)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); var saved = session; saved.name = name; try saved.data().write(to: folder.appendingPathComponent("\(safe).json"), options: .atomic); refreshPresets() } catch { self.error = error.localizedDescription }
    }
    func refreshPresets() { presets = ((try? FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("Presets"), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    func quit() {
        capturePluginStates { self.closePluginWindows(); self.finishQuit() }
        DispatchQueue.main.asyncAfter(deadline: .now()+6) { NSApp.terminate(nil) }
    }
    private func finishQuit() {
        pendingSave?.cancel(); saveLastSession(); wantsRunning = false
        let audio = audio
        audioQueue.async { audio.unloadPlugins(); DispatchQueue.main.async { NSApp.terminate(nil) } }
        // Never trap the user in a hung driver shutdown. HAL reclaims process-owned IO.
        DispatchQueue.main.asyncAfter(deadline: .now()+2) { NSApp.terminate(nil) }
    }
}

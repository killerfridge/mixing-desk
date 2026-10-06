import SwiftUI
import AppKit
import DeskModels

enum DeskAppearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"
    var colorScheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}
enum DeskStyle {
    // Native dynamic colours also follow the chosen appearance in sheets and
    // AppKit controls, without making appearance part of an audio session.
    private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let background = adaptive(0xF2F4F5, 0x0E1113)
    static let panel = adaptive(0xFFFFFF, 0x181C1F)
    static let elevated = adaptive(0xE5E9EC, 0x212629)
    static let recessed = adaptive(0xE9EDF0, 0x121517)
    static let accent = adaptive(0x9F570E, 0xF7A84D)
    static let accentText = adaptive(0xFFFFFF, 0x000000)
    static let line = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.13, darkAlpha: 0.085)
    static let meterTrack = adaptive(0x000000, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.06)
    static let output = adaptive(0x087D95, 0x32C5E8)
    static func color(_ name: String) -> Color {
        switch name {
        case "amber": return accent
        case "purple": return adaptive(0x7552B8, 0xAB8FF2)
        case "blue": return adaptive(0x286EB8, 0x61A6F0)
        case "rose": return adaptive(0xB92F65, 0xF75991)
        default: return adaptive(0x197F6B, 0x4DCCB0)
        }
    }
}
struct ContentView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.colorScheme) private var inheritedColorScheme
    @State private var page = "Desk"
    init(initialPage: String = "Desk") { _page = State(initialValue: initialPage) }
    @State private var presetName = ""
    @State private var savingPreset = false
    @AppStorage("deskDensity") private var density = "Automatic"
    @AppStorage("deskAppearance") private var appearance = DeskAppearance.system.rawValue
    var body: some View {
        GeometryReader { geometry in
            let compact = density == "Compact" || (density == "Automatic" && (geometry.size.width < 1250 || geometry.size.height < 950))
            content(compact: compact).environment(\.deskCompact, compact)
                .environment(\.colorScheme, resolvedColorScheme)
        }
        .preferredColorScheme((DeskAppearance(rawValue: appearance) ?? .system).colorScheme)
    }
    private var resolvedColorScheme: ColorScheme {
        // Observe native scheme changes. Clearing SwiftUI's preferred scheme can
        // leave its child environment at the previous value for dynamic colours.
        _ = inheritedColorScheme
        return (DeskAppearance(rawValue: appearance) ?? .system).colorScheme
            ?? (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
    }
    private func content(compact: Bool) -> some View {
        VStack(spacing: 0) {
            header(compact: compact)
            Divider().overlay(DeskStyle.line)
            HStack(spacing: 7) {
                ForEach([("Desk", "slider.vertical.3"), ("Patching", "square.grid.3x3"), ("Pipeline", "point.3.connected.trianglepath.dotted"), ("Virtual Devices", "waveform.path"), ("Setup", "gearshape")], id: \.0) { item in
                    Button { page = item.0 } label: {
                        Label(item.0, systemImage: item.1).font(.system(size: 12, weight: .semibold)).padding(.horizontal, compact ? 9 : 14).padding(.vertical, compact ? 7 : 9)
                            .foregroundStyle(page == item.0 ? DeskStyle.accent : .secondary)
                            .background(page == item.0 ? DeskStyle.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                }
                Spacer()
                Text("48 kHz").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Text("•").foregroundStyle(.quaternary)
                Text(store.running ? "\(store.actualFrames) samples" : "\(store.session.bufferFrames) samples").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.horizontal, compact ? 12 : 22).padding(.vertical, compact ? 5 : 10).background(DeskStyle.panel.opacity(0.6))
            HStack(spacing: 10) {
                if store.soloCount > 0 {
                    Button("Solo: \(store.soloCount) · Clear", action: store.clearAllSolos)
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(DeskStyle.accent)
                        .help("Clear all monitor solos (⇧⌘L).")
                }
                Spacer(minLength: 8)
                OutputProtectionIndicator(readings: store.meters, enabled: store.session.outputProtectionEnabled)
            }.padding(.horizontal, compact ? 16 : 24).padding(.vertical, 5).background(DeskStyle.panel.opacity(0.6))
            Group {
                switch page {
                case "Patching": PatchView()
                case "Pipeline": PipelineView()
                case "Virtual Devices": VirtualDevicesView()
                case "Setup": SetupView()
                default: MixerView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(DeskStyle.background).tint(DeskStyle.accent)
        .onChange(of: store.session) { _, _ in store.apply() }
        .alert("Mixing Desk", isPresented: Binding(get: { !store.showingSetupGuide && store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .sheet(isPresented: $savingPreset) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Save a desk preset").font(.title2.bold())
                TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { savingPreset = false }; Spacer(); Button("Save") { store.savePreset(presetName); savingPreset = false }.buttonStyle(.borderedProminent).disabled(presetName.isEmpty) }
            }.padding(28).frame(width: 360)
        }
        .sheet(isPresented: $store.showingSetupGuide) { SetupGuide().environmentObject(store) }
    }
    private func header(compact: Bool) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "slider.vertical.3").font(.system(size: 23, weight: .medium)).foregroundStyle(DeskStyle.accent)
                .frame(width: compact ? 32 : 46, height: compact ? 32 : 46).background(DeskStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("MIXING DESK").font(.system(size: 17, weight: .bold, design: .rounded)).tracking(2)
                Text("\(store.session.name)  /  \(store.session.strips.count) channels · \(store.session.buses.count) buses").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Appearance", selection: $appearance) {
                    ForEach(DeskAppearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                }
            } label: { Image(systemName: "circle.lefthalf.filled") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Appearance")
                .help("Appearance: \(appearance). Choose System, Light, or Dark.")
            Menu {
                Button("Open Session…", action: store.openSession)
                Button("Export Session…", action: store.exportSession)
                Divider()
                Button("Save Preset…") { presetName = store.session.name; savingPreset = true }
                ForEach(store.presets, id: \.self) { url in Button(url.deletingPathExtension().lastPathComponent) { store.load(url) } }
            } label: { Label("Session", systemImage: "folder") }.menuStyle(.borderlessButton).fixedSize()
            Button(action: store.toggleAudio) {
                HStack(spacing: 8) { Image(systemName: store.wantsRunning ? "stop.fill" : "play.fill"); Text(store.wantsRunning ? "Stop Audio" : "Start Audio") }
                    .font(.system(size: 12, weight: .bold)).padding(.horizontal, 18).padding(.vertical, 11)
                    .foregroundStyle(store.wantsRunning ? Color.primary : DeskStyle.accentText).background(store.wantsRunning ? DeskStyle.elevated : DeskStyle.accent, in: RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain)
        }.padding(.horizontal, compact ? 16 : 26).padding(.vertical, compact ? 9 : 18)
    }
    private var footer: some View {
        HStack(spacing: 9) {
            Circle().fill(store.running ? .green : .secondary).frame(width: 6, height: 6)
            Text(store.info).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if store.running {
                EngineLoadView(readings: store.engineLoad)
                Text(String(format: "~%.1f ms estimated", store.estimatedLatency + store.maximumPluginLatencyMS + store.protectionLatencyMS)).help("Core Audio estimate plus the longest active channel and output-bus plugin chains, plus protection: 96 samples / 2 ms, including during bypass. This is not a measured round-trip latency; parallel paths are not delay-compensated.")
            } else { Text("LOCAL AUDIO ENGINE") }
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12).background(DeskStyle.panel)
    }
}
struct SectionTitle: View {
    let title: String; var subtitle = ""
    var body: some View { VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 23, weight: .semibold)); if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary) } } }
}
struct MixerView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskCompact) private var compact
    @AppStorage("deskDensity") private var density = "Automatic"
    @State private var bank = "Channels"
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 18) {
            HStack(spacing: 12) {
                if compact {
                    Picker("Show", selection: $bank) { Text("Channels").tag("Channels"); Text("Buses").tag("Buses"); Text("All").tag("All") }.pickerStyle(.segmented).frame(width: 215)
                } else { SectionTitle(title: "Your desk", subtitle: "Shape each source. Send it wherever it needs to go.") }
                Spacer(minLength: 4)
                Picker("Layout", selection: $density) { ForEach(["Automatic", "Compact", "Comfortable"], id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 115).help("Desk density adapts to the window in Automatic mode.")
                Menu {
                    Picker("Monitoring", selection: $store.session.monitoringMode) { Text("Mixer Monitoring").tag("mixer"); Text("Direct Guitar").tag("directGuitar") }
                    Button("Add Channel") { store.addStrip() }.disabled(store.session.strips.count >= 64)
                    Button("Add Bus") { store.addBus() }.disabled(store.session.buses.count >= 16)
                    Toggle("Output Protection", isOn: $store.session.outputProtectionEnabled)
                    Button("Clear All Solos", action: store.clearAllSolos).disabled(store.soloCount == 0)
                    Button("Reset All Meters", action: store.resetAllMeters)
                } label: { Label("Desk", systemImage: "ellipsis.circle") }.fixedSize()
            }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: compact ? 9 : 12) {
                        if !compact || bank != "Buses" {
                            ForEach($store.session.strips) { $strip in ChannelStripView(strip: $strip).frame(width: compact ? 160 : 174) }
                        }
                        if !compact || bank == "All" { Rectangle().fill(DeskStyle.line).frame(width: 1).padding(.horizontal, 6) }
                        if !compact || bank != "Channels" {
                            ForEach($store.session.buses) { $bus in BusStripView(bus: $bus).frame(width: compact ? 158 : 166) }
                        }
                    }.environment(\.deskFaderHeight, compact ? max(90, min(150, geometry.size.height - 380)) : 208).padding(.bottom, 8)
                }
            }
            if !store.offline.isEmpty { Label("Offline: \(store.offline.joined(separator: ", "))", systemImage: "cable.connector.slash").font(.caption).foregroundStyle(.orange).lineLimit(1).help(store.offline.joined(separator: ", ")) }
        }.padding(compact ? 14 : 24)
    }
}
struct ChannelStripView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskCompact) private var compact
    @Environment(\.deskFaderHeight) private var faderHeight
    @Binding var strip: ChannelStrip
    @State private var editing = false
    @State private var editingInserts = false
    @State private var showingSends = false
    private var accent: Color { DeskStyle.color(strip.color) }
    var body: some View {
        VStack(spacing: compact ? 6 : 12) {
            RoundedRectangle(cornerRadius: 3).fill(accent).frame(height: 4)
            HStack {
                Text(strip.name.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1).lineLimit(1)
                Spacer(minLength: 1)
                Menu {
                    Button("Channel Settings…") { editing = true }
                    Toggle("Channel Protection", isOn: $strip.limiterEnabled)
                    Button("Move Left") { move(-1) }
                    Button("Move Right") { move(1) }
                    Divider()
                    Button("Remove Channel", role: .destructive) { store.removePipelineNode(PipelineNodeID(.strip, strip.id)) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
            }
            Button { editing = true } label: {
                HStack(spacing: 5) { Circle().fill(store.sourceOnline(strip.source) ? accent : .gray).frame(width: 5, height: 5); Text(store.sourceName(strip.source)).lineLimit(1); Spacer(minLength: 0); Image(systemName: "chevron.down").font(.system(size: 8)) }
                    .font(.system(size: 10)).foregroundStyle(.secondary).padding(8).background(DeskStyle.recessed, in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
            InsertButton(inserts: strip.inserts) { editingInserts = true }
            HStack {
                Text("TRIM").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary); Spacer()
                NumericLevelEditor(value: $strip.trimDB, range: -24...24, label: "\(strip.name) trim").frame(width: 65, height: 16)
            }
            ResettableSlider(value: $strip.trimDB, range: -24...24, label: "Input trim")
            HStack {
                ToggleButton(label: "M", active: $strip.muted, color: .red)
                ToggleButton(label: "S", active: $strip.solo, color: DeskStyle.accent)
                ToggleButton(label: "Ø", active: $strip.polarity, color: accent)
            }
            HStack(spacing: 18) {
                Fader(value: $strip.faderDB, tint: accent).frame(width: 72, height: faderHeight)
                LiveLevelMeter(readings: store.meters, ownerID: strip.id, isBus: false, running: store.running, reset: { [ownerID = strip.id] in store.resetMeter(ownerID: ownerID, isBus: false) }).frame(width: 30, height: faderHeight)
            }.frame(maxWidth: .infinity).padding(.vertical, 4)
            NumericLevelEditor(value: $strip.faderDB, range: -90...12, label: "\(strip.name) fader", size: 18, muted: strip.muted).frame(width: 100, height: 23)
            HStack(spacing: 4) {
                Button { strip.limiterEnabled.toggle() } label: { Image(systemName: strip.limiterEnabled ? "shield.lefthalf.filled" : "shield.slash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("\(strip.name) protection").accessibilityValue(strip.limiterEnabled ? "On" : "Bypassed")
                ChannelProtectionActivity(readings: store.meters, ownerID: strip.id, enabled: strip.limiterEnabled)
            }
            VStack(spacing: 2) {
                ResettableSlider(value: $strip.pan, range: -1...1, label: "Pan / balance", defaultDescription: "centre")
                HStack { Text("L"); Spacer(); Text(abs(strip.pan) < 0.01 ? "C" : String(format: "%.0f %@", abs(strip.pan)*100, strip.pan < 0 ? "L" : "R")); Spacer(); Text("R") }.font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
            }
            Divider().overlay(DeskStyle.line)
            if compact {
                Button { showingSends.toggle() } label: { HStack { Text("SENDS · \(strip.sends.count)"); Spacer(); Image(systemName: showingSends ? "chevron.up" : "chevron.down") }.font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
            if !compact || showingSends {
            VStack(spacing: 7) {
                ForEach($strip.sends) { $send in
                    if let bus = store.session.buses.first(where: { $0.id == send.busID }) {
                        HStack(spacing: 4) {
                            Text(bus.name).font(.system(size: 10)).lineLimit(1).frame(width: 44, alignment: .leading)
                            ResettableSlider(value: Binding(get: { send.gainDB }, set: { gain in
                                var next = send; next.gainDB = gain
                                store.setSend(from: PipelineNodeID(.strip, strip.id), to: bus.id, value: next)
                            }), range: -90...12, label: "Send to \(bus.name)", onEditingChanged: { store.trackRoutingGesture($0, name: "Send Level") })
                            Button(send.preFader ? "PRE" : "POST") {
                                var next = send; next.preFader.toggle()
                                store.setSend(from: PipelineNodeID(.strip, strip.id), to: bus.id, value: next)
                            }.font(.system(size: 8, weight: .semibold)).buttonStyle(.plain).foregroundStyle(send.preFader ? accent : .secondary).frame(width: 28)
                        }.help(send.gainDB <= -90 ? "Send off" : String(format: "Send %+.1f dB", send.gainDB))
                    }
                }
            }.frame(minHeight: compact ? 0 : 64, alignment: .top)
            }
            if strip.role == "guitar" && store.session.monitoringMode == "directGuitar" { Text("HEADPHONES: HARDWARE").font(.system(size: 8, weight: .bold)).foregroundStyle(accent) }
        }.padding(compact ? 10 : 13).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskStyle.line))
            .sheet(isPresented: $editing) { PipelineChannelEditor(strip: strip).environmentObject(store) }
            .sheet(isPresented: $editingInserts) { InsertEditor(inserts: $strip.inserts, ownerName: strip.name, isBus: false) }
    }
    private func move(_ direction: Int) { guard let i = store.session.strips.firstIndex(where: { $0.id == strip.id }) else { return }; let j = i+direction; guard store.session.strips.indices.contains(j) else { return }; store.edit { $0.strips.swapAt(i,j) } }
}
struct BusStripView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskCompact) private var compact
    @Environment(\.deskFaderHeight) private var faderHeight
    @Binding var bus: Bus
    @State private var nameDraft: String
    @FocusState private var editingName: Bool
    init(bus: Binding<Bus>) { _bus = bus; _nameDraft = State(initialValue: bus.wrappedValue.name) }
    @State private var editingInserts = false
    var body: some View {
        VStack(spacing: compact ? 8 : 14) {
            RoundedRectangle(cornerRadius: 3).fill(DeskStyle.accent.opacity(0.7)).frame(height: 4)
            TextField("Bus", text: $nameDraft).textFieldStyle(.plain).font(.system(size: 12, weight: .bold)).multilineTextAlignment(.center)
                .focused($editingName).onSubmit(saveName)
                .onChange(of: editingName) { _, editing in if !editing { saveName() } }
                .onChange(of: bus.name) { _, name in if !editingName { nameDraft = name } }
            Text(bus.kind == "monitor" ? "HEADPHONE MIX" : bus.kind == "call" ? "MIX-MINUS" : "OUTPUT BUS").font(.system(size: 9, weight: .medium)).tracking(1).foregroundStyle(DeskStyle.accent)
            InsertButton(inserts: bus.inserts) { editingInserts = true }
            ToggleButton(label: "MUTE", active: $bus.muted, color: .red)
            HStack(spacing: 18) { Fader(value: $bus.gainDB, tint: DeskStyle.accent).frame(width: 68, height: faderHeight); LiveLevelMeter(readings: store.meters, ownerID: bus.id, isBus: true, running: store.running, reset: { [ownerID = bus.id] in store.resetMeter(ownerID: ownerID, isBus: true) }).frame(width: 28, height: faderHeight) }.padding(.vertical, 4)
            NumericLevelEditor(value: $bus.gainDB, range: -90...12, label: "\(bus.name) level", size: 18, muted: bus.muted).frame(width: 100, height: 23)
            if bus.kind == "call" {
                VStack(alignment: .leading, spacing: 5) {
                    Text("EXCLUDE RETURN").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                    Picker("Return", selection: Binding(get: { bus.excludedStripID }, set: { id in
                        store.routeEdit("Change Mix-minus") { s in if let i = s.buses.firstIndex(where: { $0.id == bus.id }) { s.buses[i].excludedStripID = id } }
                    })) { Text("None").tag(""); ForEach(store.session.strips) { Text($0.name).tag($0.id) } }.labelsHidden().controlSize(.small)
                }
            } else { Text(bus.kind == "monitor" ? "Solo affects this mix only" : "Independent output level").font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 37) }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.session.routes.filter { $0.sourceKind == "bus" && $0.sourceID == bus.id }) { route in
                    Label(store.devices.first { $0.uid == route.destinationUID }?.name ?? "Output offline", systemImage: "arrow.up.right").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                if !store.session.routes.contains(where: { $0.sourceKind == "bus" && $0.sourceID == bus.id }) { Text("No output patched").font(.system(size: 10)).foregroundStyle(.tertiary) }
            }.frame(maxWidth: .infinity, minHeight: compact ? 24 : 68, alignment: .topLeading)
            if bus.kind != "monitor" { Button("Remove Bus", role: .destructive) { store.removePipelineNode(PipelineNodeID(.bus, bus.id)) }.buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(.secondary) }
        }.padding(compact ? 10 : 13).background(DeskStyle.elevated.opacity(0.7), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskStyle.accent.opacity(0.14)))
            .sheet(isPresented: $editingInserts) { InsertEditor(inserts: $bus.inserts, ownerName: bus.name, isBus: true) }
    }
    private func saveName() {
        store.routeEdit("Rename Bus") { s in if let i = s.buses.firstIndex(where: { $0.id == bus.id }) { s.buses[i].name = nameDraft } }
    }
}
private struct EngineLoadView: View {
    @ObservedObject var readings: DeskLoad
    var body: some View {
        Text(String(format: "DSP %.1f%%", readings.value.load*100))
        Text("\(readings.value.underruns) overruns").foregroundStyle(readings.value.underruns > 0 ? .orange : .secondary)
    }
}
private struct LiveLevelMeter: View {
    @ObservedObject var readings: DeskMeters
    let ownerID: String
    let isBus: Bool
    let running: Bool
    var reset: () -> Void
    private var value: MeterValue { let value = readings.value.meter(ownerID: ownerID, isBus: isBus); return running ? value : value.quiet }
    var body: some View {
        Button(action: reset) { LevelMeter(value: value) }.buttonStyle(.plain)
            .accessibilityLabel("\(isBus ? "Bus" : "Channel") meter")
            .accessibilityValue("Held peak \(value.heldDescription) dBFS\(value.clip ? ", overload" : "")")
            .accessibilityAction(named: Text("Reset meter"), reset)
            .help(isBus ? "Held peak in dBFS. Click to reset this bus's peak and overload latch. Meter is after bus inserts/master; final output protection follows output-route gains and summing." : "Protected post-fader peak in dBFS, before pan. Click to reset this channel's held peak and overload latch.")
    }
}
struct ToggleButton: View {
    let label: String; @Binding var active: Bool; var color: Color
    var body: some View { Button { active.toggle() } label: { Text(label).font(.system(size: 10, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 7).foregroundStyle(active ? DeskStyle.accentText : Color.secondary).background(active ? color : DeskStyle.recessed, in: RoundedRectangle(cornerRadius: 4)) }.buttonStyle(.plain).accessibilityLabel(label == "M" ? "Mute" : label == "S" ? "Solo in monitor" : label == "Ø" ? "Invert polarity" : label).accessibilityValue(active ? "On" : "Off") }
}
struct Fader: View {
    @Binding var value: Double
    var tint: Color
    private func position(_ db: Double) -> Double { db <= -60 ? (db+90)/30*0.12 : 0.12+(db+60)/72*0.88 }
    private func decibels(_ position: Double) -> Double { position < 0.12 ? -90+position/0.12*30 : -60+(position-0.12)/0.88*72 }
    var body: some View {
        GeometryReader { geo in
            let travel = geo.size.height-24
            ZStack(alignment: .top) {
                Capsule().fill(.black.opacity(0.65)).frame(width: 7).padding(.vertical, 12)
                ForEach(geo.size.height < 150 ? [12, 0, -12, -48, -90] : [12, 6, 0, -6, -12, -24, -48, -90], id: \.self) { mark in
                    HStack { Text(mark == -90 ? "∞" : "\(mark)").font(.system(size: 8, design: .monospaced)).foregroundStyle(mark == 0 ? tint : .secondary).frame(width: 20, alignment: .trailing); Rectangle().fill(mark == 0 ? tint.opacity(0.6) : DeskStyle.line).frame(width: 28, height: 1); Spacer(minLength: 0) }.offset(y: 12+travel*(1-position(Double(mark)))-5)
                }
                RoundedRectangle(cornerRadius: 4).fill(LinearGradient(colors: [.white.opacity(0.85), .gray.opacity(0.8)], startPoint: .top, endPoint: .bottom)).frame(width: 32, height: 24)
                    .overlay(Rectangle().fill(.black.opacity(0.8)).frame(height: 2).padding(.horizontal, 4))
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 3)
                    .offset(x: 7, y: travel*(1-position(min(12,max(-90,value)))))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
                .overlay(FaderMouseSurface(currentPosition: { 12+travel*(1-position(min(12,max(-90,value)))) }, onPosition: { y, fine in
                    let fraction = 1.0 - Double(y - CGFloat(12)) / Double(travel)
                    let precision = fine ? 100.0 : 10.0
                    value = (decibels(min(1.0, max(0.0, fraction))) * precision).rounded() / precision
                }, onReset: { value = 0 }))
                .help("Drag to adjust. Shift-drag at one-tenth sensitivity. Double-click to reset to 0 dB.")
        }.accessibilityElement().accessibilityLabel("Fader").accessibilityValue("\(value) decibels").accessibilityAdjustableAction { direction in value = min(12,max(-90,value+(direction == .increment ? 1 : -1))) }
    }
}
struct LevelMeter: View {
    let value: MeterValue
    private func level(_ amplitude: Float) -> Double { min(1,max(0,(20*log10(Double(max(0.00001,amplitude)))+60)/60)) }
    var body: some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(value.clip ? .red : .red.opacity(0.12)).frame(height: 5)
            Canvas { context,size in
                let gap: CGFloat = 2, width = (size.width-4)/2, segments = 36
                for channel in 0..<2 {
                    let peak = level(channel == 0 ? value.peakL : value.peakR), rms = level(channel == 0 ? value.rmsL : value.rmsR)
                    for i in 0..<segments {
                        let fraction = Double(i)/Double(segments), h = size.height/CGFloat(segments), rect = CGRect(x: CGFloat(channel)*(width+4), y: size.height-CGFloat(i+1)*h, width: width, height: max(1,h-gap))
                        let color: Color = fraction > 0.94 ? .red : fraction > 0.77 ? .orange : Color(red: 0.36, green: 0.80, blue: 0.53)
                        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(fraction < rms ? 1 : fraction < peak ? 0.5 : 0.09)))
                    }
                }
            }
            Text(value.heldDescription).font(.system(size: 8, weight: .medium, design: .monospaced)).fixedSize()
            Text("dBFS").font(.system(size: 7)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("Held peak \(value.heldDescription) dBFS")
    }
}

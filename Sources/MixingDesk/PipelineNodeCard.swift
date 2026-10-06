import SwiftUI
import DeskModels

struct PipelineNodeCard<Actions: View>: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.colorScheme) private var colorScheme
    let node: PipelineNodeID
    let selected: Bool
    let compatible: Bool
    let name: String
    var metersVisible = true
    var select: () -> Void
    var configure: () -> Void
    var inserts: () -> Void
    var move: (CGSize) -> Void
    var moved: () -> Void
    @ViewBuilder var actions: () -> Actions
    private var strip: ChannelStrip? { store.session.strips.first { node.kind == .strip && $0.id == node.rawID } }
    private var bus: Bus? { store.session.buses.first { node.kind == .bus && $0.id == node.rawID } }
    private var device: Device? { store.devices.first { node.kind == .output && $0.uid == node.rawID } }
    private var color: Color { node.kind == .output ? DeskStyle.output : DeskStyle.color(strip?.color ?? "amber") }
    private var chain: [InsertSlot] { strip?.inserts ?? bus?.inserts ?? [] }
    private var online: Bool { strip.map { store.sourceOnline($0.source) } ?? (node.kind == .bus || device != nil) }
    private var icon: String {
        if let strip { return strip.source.kind == "application" ? "app.connected.to.app.below.fill" : "waveform" }
        if node.kind == .bus { return bus?.kind == "call" ? "arrow.triangle.branch" : "square.stack.3d.up" }
        return node.rawID.hasPrefix("local.mixingdesk.virtual.") ? "waveform.path" : "hifispeaker.fill"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: icon).foregroundStyle(color).frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.kind == .strip ? "CHANNEL" : node.kind == .bus ? "BUS" : "OUTPUT").font(.system(size: 8, weight: .bold)).tracking(1.4).foregroundStyle(color)
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("pipelineGraph")).onChanged { move($0.translation) }.onEnded { _ in moved() })
                    .help("Drag the title to move this block.")
                Menu { actions() } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 19)
                    .accessibilityLabel("\(name) actions")
            }
            HStack(spacing: 5) {
                Circle().fill(online ? color : .orange).frame(width: 5, height: 5)
                if let strip {
                    Button(action: configure) { Text(store.sourceName(strip.source)).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8)) }
                        .buttonStyle(.plain).accessibilityLabel("Choose source for \(name)")
                } else if let bus {
                    Text(bus.kind == "monitor" ? "Monitor mix · solo applies here" : bus.kind == "call" ? "Call mix-minus" : "Independent mix").lineLimit(1)
                } else {
                    Text(device.map { "\($0.outputs.count) output channels · \(node.rawID.hasPrefix("local.mixingdesk.virtual.") ? "virtual" : "audio device")" } ?? "Offline · saved routes retained").lineLimit(1)
                }
            }.font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 20)
            Divider().overlay(DeskStyle.line)
            if node.kind != .output {
                Button(action: inserts) {
                    VStack(alignment: .leading, spacing: 4) {
                        if chain.isEmpty { Label("Add effects…", systemImage: "plus.circle").foregroundStyle(.secondary) }
                        ForEach(Array(chain.enumerated()), id: \.element.id) { index, slot in
                            HStack(spacing: 5) {
                                Text("\(index+1)").foregroundStyle(.tertiary).frame(width: 10)
                                Text(slot.displayName).lineLimit(1)
                                Spacer(minLength: 2)
                                if slot.bypassed { Text("BYP").font(.system(size: 8)).foregroundStyle(.secondary) }
                            }.foregroundStyle(slot.bypassed ? .secondary : .primary)
                        }
                    }.font(.system(size: 10)).frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
                }.buttonStyle(.plain).accessibilityLabel("Edit inserts for \(name)")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    let routes = store.session.routes.filter { $0.destinationUID == node.rawID }
                    Text("\(routes.count) \(routes.count == 1 ? "connection" : "connections")").font(.system(size: 12, weight: .medium))
                    ForEach(Array(routes.prefix(2))) { route in
                        Text("Ch \(route.channels.map { String($0+1) }.joined(separator: " / ")) · \(route.channels.count == 1 ? "Mono" : "Stereo")").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    if routes.count > 2 { Text("+\(routes.count-2) more · Connections menu").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if routes.isEmpty { Text("Drag a cable here to choose channels.").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
            }
            Spacer(minLength: 0)
            if node.kind != .output {
                if metersVisible {
                    PipelineMeter(readings: store.meters, ownerID: node.rawID, isBus: node.kind == .bus, running: store.running, reset: { store.resetMeter(ownerID: node.rawID, isBus: node.kind == .bus) })
                } else {
                    PipelineMeterDisplay(value: store.meters.value.meter(ownerID: node.rawID, isBus: node.kind == .bus), isBus: node.kind == .bus, reset: { store.resetMeter(ownerID: node.rawID, isBus: node.kind == .bus) })
                }
                PipelineLevelControls(node: node, name: name, metersVisible: metersVisible)
                HStack(spacing: 5) {
                    if let bus, let excluded = store.session.strips.first(where: { $0.id == bus.excludedStripID }) {
                        Label("Excludes \(excluded.name)", systemImage: "nosign").foregroundStyle(.orange).lineLimit(1)
                    } else { Text(strip.map { $0.source.channels.count == 1 ? "MONO INPUT" : "STEREO INPUT" } ?? "STEREO MIX").foregroundStyle(.secondary) }
                    Spacer(minLength: 1)
                }.font(.system(size: 9, design: .monospaced))
            } else {
                HStack {
                    if store.session.monitorDeviceUID == node.rawID { Label("Monitoring / clock", systemImage: "headphones").foregroundStyle(DeskStyle.accent) }
                    else { Text("OUTPUT DESTINATION").foregroundStyle(.secondary) }
                    Spacer()
                }.font(.system(size: 10)).frame(height: 28)
            }
        }
        .padding(14).frame(width: PipelineGeometry.card.width, height: PipelineGeometry.card.height)
        .background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .top) { RoundedRectangle(cornerRadius: 2).fill(color).frame(height: 3).padding(.horizontal, 14) }
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(compatible ? .green : selected ? color : DeskStyle.line, lineWidth: compatible || selected ? 2 : 1))
        .shadow(color: .black.opacity(colorScheme == .light ? 0.07 : 0.18), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture(perform: select)
        .contextMenu { actions() }
        .accessibilityElement(children: .contain).accessibilityLabel("\(name), \(node.kind.rawValue)\(online ? "" : ", offline")")
    }
}

/// Uses stable node IDs so removal, reordering and routing undo cannot leave a
/// control editing the wrong channel. Levels share the Desk's live update path.
struct PipelineLevelControls: View {
    @EnvironmentObject var store: DeskStore
    let node: PipelineNodeID
    let name: String
    var metersVisible = true
    private func binding<T>(_ stripKey: WritableKeyPath<ChannelStrip, T>, _ busKey: WritableKeyPath<Bus, T>, fallback: T) -> Binding<T> {
        Binding(get: {
            if node.kind == .strip { return store.session.strips.first { $0.id == node.rawID }?[keyPath: stripKey] ?? fallback }
            return store.session.buses.first { $0.id == node.rawID }?[keyPath: busKey] ?? fallback
        }, set: { value in
            store.edit { session in
                if node.kind == .strip, let i = session.strips.firstIndex(where: { $0.id == node.rawID }) { session.strips[i][keyPath: stripKey] = value }
                else if node.kind == .bus, let i = session.buses.firstIndex(where: { $0.id == node.rawID }) { session.buses[i][keyPath: busKey] = value }
            }
        })
    }
    private var solo: Binding<Bool> {
        Binding(get: { store.session.strips.first { $0.id == node.rawID }?.solo ?? false }, set: { value in
            store.edit { session in
                if let i = session.strips.firstIndex(where: { $0.id == node.rawID }) { session.strips[i].solo = value }
            }
        })
    }
    var body: some View {
        let level = binding(\.faderDB, \.gainDB, fallback: 0)
        let muted = binding(\.muted, \.muted, fallback: false)
        VStack(spacing: 3) {
            HStack(spacing: 5) {
                Text("LEVEL").foregroundStyle(.secondary)
                NumericLevelEditor(value: level, range: -90...12, label: "\(name) level", size: 9, muted: muted.wrappedValue).frame(width: 60, height: 17)
                Spacer(minLength: 2)
                toggle("M", value: muted, color: .red, label: "Mute \(name)")
                if node.kind == .strip { toggle("S", value: solo, color: DeskStyle.accent, label: "Solo \(name) in monitor") }
            }.font(.system(size: 9, weight: .medium, design: .monospaced)).frame(height: 18)
            ResettableSlider(value: level, range: -90...12, label: "\(name) level").frame(height: 16)
            if node.kind == .strip {
                HStack(spacing: 5) {
                    Text("TRIM").font(.system(size: 9)).foregroundStyle(.secondary)
                    NumericLevelEditor(value: binding(\.trimDB, \.gainDB, fallback: 0), range: -24...24, label: "\(name) trim", size: 9).frame(width: 62, height: 16)
                    Spacer(minLength: 0)
                    if metersVisible {
                        ChannelProtectionActivity(readings: store.meters, ownerID: node.rawID, enabled: store.session.strips.first { $0.id == node.rawID }?.limiterEnabled ?? true)
                    } else {
                        Text(store.session.strips.first { $0.id == node.rawID }?.limiterEnabled == false ? "BYPASS" : "PROTECT").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func toggle(_ title: String, value: Binding<Bool>, color: Color, label: String) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            Text(title).frame(width: 23, height: 18)
                .foregroundStyle(value.wrappedValue ? DeskStyle.accentText : Color.secondary)
                .background(value.wrappedValue ? color : DeskStyle.recessed, in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityValue(value.wrappedValue ? "On" : "Off")
            .help(title == "M" ? "Mute this signal." : "Solo in the monitor mix only.")
    }
}

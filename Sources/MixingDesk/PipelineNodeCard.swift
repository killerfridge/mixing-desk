import SwiftUI
import DeskModels

struct PipelineNodeCard<Actions: View>: View {
    @EnvironmentObject var store: DeskStore
    let node: PipelineNodeID
    let selected: Bool
    let compatible: Bool
    let name: String
    var select: () -> Void
    var configure: () -> Void
    var inserts: () -> Void
    var move: (CGSize) -> Void
    var moved: () -> Void
    @ViewBuilder var actions: () -> Actions
    private var strip: ChannelStrip? { store.session.strips.first { node.kind == .strip && $0.id == node.rawID } }
    private var bus: Bus? { store.session.buses.first { node.kind == .bus && $0.id == node.rawID } }
    private var device: Device? { store.devices.first { node.kind == .output && $0.uid == node.rawID } }
    private var color: Color { node.kind == .output ? .cyan : DeskStyle.color(strip?.color ?? "amber") }
    private var chain: [InsertSlot] { strip?.inserts ?? bus?.inserts ?? [] }
    private var online: Bool { strip.map { store.sourceOnline($0.source) } ?? (node.kind == .bus || device != nil) }
    private var icon: String {
        if let strip { return strip.source.kind == "application" ? "app.connected.to.app.below.fill" : "waveform" }
        if node.kind == .bus { return bus?.kind == "call" ? "arrow.triangle.branch" : "square.stack.3d.up" }
        return node.rawID.hasPrefix("local.mixingdesk.virtual.") ? "waveform.path" : "hifispeaker.fill"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                PipelineMeter(readings: store.meters, index: node.kind == .strip ? store.session.strips.firstIndex { $0.id == node.rawID } : store.session.buses.firstIndex { $0.id == node.rawID }, isBus: node.kind == .bus, running: store.running)
                HStack(spacing: 5) {
                    if let bus, let excluded = store.session.strips.first(where: { $0.id == bus.excludedStripID }) {
                        Label("Excludes \(excluded.name)", systemImage: "nosign").foregroundStyle(.orange).lineLimit(1)
                    } else { Text(strip.map { $0.source.channels.count == 1 ? "MONO INPUT" : "STEREO INPUT" } ?? "STEREO MIX").foregroundStyle(.secondary) }
                    Spacer(minLength: 1)
                    Text((strip?.muted ?? bus?.muted ?? false) ? "MUTED" : String(format: "%+.0f dB", strip?.faderDB ?? bus?.gainDB ?? 0)).foregroundStyle(.secondary)
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
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: 12)).onTapGesture(perform: select)
        .contextMenu { actions() }
        .accessibilityElement(children: .contain).accessibilityLabel("\(name), \(node.kind.rawValue)\(online ? "" : ", offline")")
    }
}

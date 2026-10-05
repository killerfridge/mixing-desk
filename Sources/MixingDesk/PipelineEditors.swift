import SwiftUI
import DeskModels

struct PipelineChannelEditor: View {
    @EnvironmentObject var store: DeskStore
    @State var strip: ChannelStrip
    var body: some View {
        ChannelSettingsView(strip: $strip, onCommit: store.configureChannel)
    }
}
struct PipelineBusEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State var bus: Bus
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "Bus settings")
            Form {
                TextField("Name", text: $bus.name)
                Picker("Exclude source", selection: $bus.excludedStripID) {
                    Text("None").tag("")
                    ForEach(store.session.strips) { Text($0.name).tag($0.id) }
                }
                Text("Mix-minus excludes every channel with the same source identity, including contributions arriving through other buses.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Apply") {
                if store.routeEdit("Configure Bus", { s in
                    guard let i = s.buses.firstIndex(where: { $0.id == bus.id }) else { throw SessionError.invalid("This bus no longer exists.") }
                    s.buses[i].name = bus.name; s.buses[i].excludedStripID = bus.excludedStripID
                }) { dismiss() }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 440, height: 290).pipelineErrorAlert()
    }
}
struct PipelineOutputPicker: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "Add an output", subtitle: "Choose a destination. Connect a cable to send audio to it.")
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(store.devices.filter { !$0.outputs.isEmpty }) { device in
                        Button {
                            store.addOutput(device.uid); dismiss()
                        } label: {
                            HStack {
                                Image(systemName: device.uid.hasPrefix("local.mixingdesk.virtual.") ? "waveform.path" : "hifispeaker")
                                VStack(alignment: .leading) { Text(device.name); Text("\(device.outputs.count) channels · \(device.supports48k ? "48 kHz" : "Unsupported sample rate")").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "plus")
                            }.padding(12).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).disabled(!device.supports48k)
                    }
                    if store.devices.filter({ !$0.outputs.isEmpty }).isEmpty { Text("No outputs found. Connect an audio device, then refresh.").foregroundStyle(.secondary) }
                }
            }
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Refresh", action: store.refreshDiscovery) }
        }.padding(24).frame(width: 460, height: 390)
    }
}
struct PipelineConnectionEditor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    private let sendSource: PipelineNodeID?
    private let busID: String?
    private let connection: PipelineConnection?
    @State private var route: OutputRoute
    @State private var gain: Double
    @State private var pre: Bool
    @State private var left: Int
    @State private var right: Int
    @State private var stereo: Bool
    init(route: OutputRoute) {
        sendSource = nil; busID = nil; connection = nil
        _route = State(initialValue: route); _gain = State(initialValue: route.gainDB); _pre = State(initialValue: route.preFader)
        _left = State(initialValue: route.channels.first ?? 0); _right = State(initialValue: route.channels.count > 1 ? route.channels[1] : 1); _stereo = State(initialValue: route.channels.count > 1)
    }
    init(edge: PipelineEdge, session: Session) {
        connection = edge.id
        if case let .send(source, bus) = edge.id { sendSource = source; busID = bus }
        else { sendSource = nil; busID = nil }
        let saved: OutputRoute
        if case let .route(id) = edge.id, let value = session.routes.first(where: { $0.id == id }) { saved = value }
        else { saved = OutputRoute(sourceKind: edge.source.kind.rawValue, sourceID: edge.source.rawID, destinationUID: edge.destination.rawID) }
        _route = State(initialValue: saved); _gain = State(initialValue: edge.gainDB); _pre = State(initialValue: edge.preFader)
        _left = State(initialValue: saved.channels.first ?? 0); _right = State(initialValue: saved.channels.count > 1 ? saved.channels[1] : 1); _stereo = State(initialValue: saved.channels.count > 1)
    }
    private var device: Device? { store.devices.first { $0.uid == route.destinationUID } }
    private var channelCount: Int { max(device?.outputs.count ?? 0, (route.channels.max() ?? 0)+1) }
    private var supportsPre: Bool { sendSource.map { $0.kind == .strip } ?? (route.sourceKind == "strip") }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: connection == nil ? "Connect output" : "Connection settings", subtitle: description)
            Form {
                HStack {
                    Text("Level")
                    ResettableSlider(value: $gain, range: -90...12, label: "Connection level")
                    Text(gain <= -90 ? "Off" : String(format: "%+.1f dB", gain)).font(.system(.caption, design: .monospaced)).frame(width: 65)
                }
                if supportsPre { Toggle("Pre-fader", isOn: $pre) }
                if sendSource == nil {
                    Toggle("Stereo pair", isOn: $stereo).disabled(device == nil || channelCount < 2)
                    Picker(stereo ? "Left channel" : "Channel", selection: $left) { ForEach(0..<channelCount, id: \.self) { Text(channelName($0)).tag($0) } }.disabled(device == nil)
                    if stereo { Picker("Right channel", selection: $right) { ForEach(0..<channelCount, id: \.self) { Text(channelName($0)).tag($0) } }.disabled(device == nil) }
                    if device == nil { Text("Output offline. Its saved mapping is retained; reconnect it to change channels.").font(.caption).foregroundStyle(.orange) }
                }
                if let source = sendSource, let bus = store.session.buses.first(where: { $0.id == busID }), let strip = store.session.strips.first(where: { source.kind == .strip && $0.id == source.rawID }), PipelineGraph.excludes(bus, source: strip.source, in: store.session) {
                    Label("This source is excluded by this bus's mix-minus setting.", systemImage: "nosign").font(.caption).foregroundStyle(.orange)
                }
            }.formStyle(.grouped)
            HStack {
                if let connection { Button("Disconnect", role: .destructive) { store.disconnect(connection); dismiss() } }
                Button("Cancel") { dismiss() }; Spacer()
                Button(connection == nil ? "Connect" : "Apply") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(sendSource == nil && stereo && left == right)
            }
        }.padding(24).frame(width: 500, height: sendSource == nil ? 390 : 280).pipelineErrorAlert()
    }
    private var description: String {
        let sourceID = sendSource?.rawID ?? route.sourceID
        let source = store.session.strips.first { $0.id == sourceID }?.name ?? store.session.buses.first { $0.id == sourceID }?.name ?? "Source"
        let destination = busID.flatMap { id in store.session.buses.first { $0.id == id }?.name } ?? device?.name ?? "Saved output"
        return "\(source) → \(destination)"
    }
    private func channelName(_ index: Int) -> String { "\(index+1) · \(device.flatMap { $0.outputs.indices.contains(index) ? $0.outputs[index] : nil } ?? "Saved channel")" }
    private func save() {
        let saved: Bool
        if let source = sendSource, let busID { saved = store.setSend(from: source, to: busID, value: Send(busID: busID, gainDB: gain, preFader: pre)) }
        else {
            route.gainDB = gain; route.preFader = pre; route.channels = stereo ? [left,right] : [left]
            saved = store.saveRoute(route)
        }
        if saved { dismiss() }
    }
}
private struct PipelineErrorAlert: ViewModifier {
    @EnvironmentObject var store: DeskStore
    func body(content: Content) -> some View {
        content.alert("Cannot change routing", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }
}
extension View { func pipelineErrorAlert() -> some View { modifier(PipelineErrorAlert()) } }

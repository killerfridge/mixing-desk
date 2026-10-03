import SwiftUI
import DeskModels

struct ChannelSettingsView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @Binding var strip: ChannelStrip
    private var count: Int { strip.source.kind == "application" ? 2 : store.devices.first { $0.uid == strip.source.deviceUID }?.inputs.count ?? 0 }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionTitle(title: "Channel settings", subtitle: "Select the source and its individual audio channels.")
            Form {
                TextField("Name", text: $strip.name)
                Picker("Colour", selection: $strip.color) { ForEach(["teal", "amber", "purple", "blue", "rose"], id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Role", selection: $strip.role) { Text("General").tag("generic"); Text("Guitar").tag("guitar"); Text("Call return").tag("callReturn") }
                Picker("Source", selection: $strip.source.kind) { Text("Audio device").tag("device"); Text("Application").tag("application") }
                if strip.source.kind == "device" {
                    Picker("Device", selection: Binding(get: { strip.source.deviceUID }, set: { uid in
                        strip.source.deviceUID = uid
                        if let device = store.devices.first(where: { $0.uid == uid }), !device.inputs.isEmpty {
                            if device.inputs.count == 1 { strip.source.channels = [0] }
                            else if strip.source.channels.contains(where: { $0 >= device.inputs.count }) { strip.source.channels = strip.source.channels.count == 1 ? [0] : [0,1] }
                        }
                    })) {
                        Text("Select an input").tag("")
                        ForEach(store.devices.filter { !$0.inputs.isEmpty }) { Text($0.name).tag($0.uid) }
                        if !strip.source.deviceUID.isEmpty && !store.devices.contains(where: { $0.uid == strip.source.deviceUID }) { Text("Saved device · offline").tag(strip.source.deviceUID) }
                    }
                    Picker("Virtual return from", selection: $strip.source.returnBundleID) {
                        Text("No associated application").tag("")
                        ForEach(store.apps) { Text($0.name).tag($0.bundleID) }
                        if !strip.source.returnBundleID.isEmpty && !store.apps.contains(where: { $0.bundleID == strip.source.returnBundleID }) { Text(strip.source.returnBundleID).tag(strip.source.returnBundleID) }
                    }
                    Text("Associate a virtual return with its application to prevent capturing it twice.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Application", selection: $strip.source.bundleID) {
                        Text("Select an application").tag("")
                        ForEach(store.apps) { Text($0.name).tag($0.bundleID) }
                        if !strip.source.bundleID.isEmpty && !store.apps.contains(where: { $0.bundleID == strip.source.bundleID }) { Text("\(strip.source.bundleID) · offline").tag(strip.source.bundleID) }
                    }
                    Text("Applications appear after creating an audio stream. Their normal playback is muted while captured by the desk.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Format", selection: Binding(get: { strip.source.channels.count }, set: { strip.source.channels = $0 == 1 ? [0] : [0,1] })) { Text("Mono").tag(1); Text("Stereo").tag(2) }
                ForEach(strip.source.channels.indices, id: \.self) { index in
                    Picker(index == 0 ? "Input / Left" : "Right", selection: Binding(get: { strip.source.channels[index] }, set: { channel in
                        var channels = strip.source.channels
                        if let other = channels.firstIndex(of: channel), other != index { channels[other] = channels[index] }
                        channels[index] = channel; strip.source.channels = channels
                    })) {
                        ForEach(0..<max(count,(strip.source.channels.max() ?? 0)+1), id: \.self) { c in
                            Text(channelName(c)).tag(c)
                        }
                    }
                }
                Text("Quad Cortex: choose the USB channels carrying your intended wet or dry signal. The desk does not change your hardware preset.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 520, height: 620)
    }
    private func channelName(_ index: Int) -> String {
        if strip.source.kind == "device", let device = store.devices.first(where: { $0.uid == strip.source.deviceUID }), device.inputs.indices.contains(index) { return "\(index+1) · \(device.inputs[index])" }
        return "Channel \(index+1)"
    }
}

struct PatchView: View {
    @Environment(\.deskCompact) private var compact
    @EnvironmentObject var store: DeskStore
    @State private var addRoute = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    SectionTitle(title: "Patch bay", subtitle: "Rows feed columns. Click to connect; use the menu to change a send.")
                    Spacer()
                    Button { addRoute = true } label: { Label("Patch Output", systemImage: "plus") }
                }
                ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("SOURCE → BUS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 210, alignment: .leading)
                        ForEach(store.session.buses) { bus in Text(bus.name).font(.system(size: 11, weight: .bold)).frame(width: 100, height: 46) }
                    }.padding(.horizontal, 16)
                    ForEach(store.session.strips) { strip in matrixRow(id: strip.id, name: strip.name, kind: "strip", color: DeskStyle.color(strip.color)) }
                    Divider()
                    ForEach(store.session.buses) { bus in matrixRow(id: bus.id, name: bus.name, kind: "bus", color: DeskStyle.accent) }
                }.background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(DeskStyle.line))
                }
                (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 20))) {
                    Label("PRE · independent of channel fader", systemImage: "circle.fill")
                    Label("POST · follows channel fader", systemImage: "circle")
                    Label("Mix-minus exclusions apply through every bus", systemImage: "arrow.triangle.branch")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                SectionTitle(title: "Output patches", subtitle: "Send a bus mix or a direct channel signal to a hardware or virtual-device channel.")
                if store.session.routes.isEmpty {
                    ContentUnavailableView("No output patches", systemImage: "cable.connector", description: Text("Choose your headphone output in Setup, or add a patch here."))
                } else {
                    VStack(spacing: 1) {
                        ForEach($store.session.routes) { $route in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 12) {
                                    Label(sourceName(route), systemImage: route.sourceKind == "bus" ? "square.stack" : "slider.vertical.3").font(.system(size: 12, weight: .semibold)).frame(minWidth: 100, alignment: .leading)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(store.devices.first { $0.uid == route.destinationUID }?.name ?? "Saved output · offline").font(.system(size: 12))
                                        Text("Channels \(route.channels.map { String($0+1) }.joined(separator: " / "))").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button(role: .destructive) { store.edit { $0.routes.removeAll { $0.id == route.id } } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 12) {
                                    if route.sourceKind == "strip" { Toggle("Pre-fader", isOn: $route.preFader).toggleStyle(.checkbox).font(.caption) }
                                    Text("LEVEL").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                    ResettableSlider(value: $route.gainDB, range: -90...12, label: "Output route level").frame(maxWidth: 220)
                                    Text(route.gainDB <= -90 ? "−∞" : String(format: "%+.1f dB", route.gainDB)).font(.system(size: 10, design: .monospaced)).frame(width: 60)
                                    Spacer()
                                }
                            }.padding(16).background(DeskStyle.panel)
                        }
                    }.clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("For Logic, create a multichannel virtual device and patch individual strips to separate input channels. Monitor-only solo never changes these recording feeds.").font(.caption).foregroundStyle(.secondary)
            }.padding(compact ? 16 : 26).frame(maxWidth: .infinity, alignment: .leading)
        }.sheet(isPresented: $addRoute) { AddRouteView().environmentObject(store) }
    }
    private func sourceName(_ route: OutputRoute) -> String { route.sourceKind == "bus" ? store.session.buses.first { $0.id == route.sourceID }?.name ?? "Bus" : store.session.strips.first { $0.id == route.sourceID }?.name ?? "Channel" }
    private func send(kind: String, id: String, busID: String) -> Send? { kind == "strip" ? store.session.strips.first { $0.id == id }?.sends.first { $0.busID == busID } : store.session.buses.first { $0.id == id }?.sends.first { $0.busID == busID } }
    private func patch(kind: String, id: String, busID: String, mode: String) {
        store.edit { s in
            func mutate(_ sends: inout [Send]) {
                if let index = sends.firstIndex(where: { $0.busID == busID }) {
                    if mode == "toggle" { sends.remove(at: index) }
                    else if mode == "pre" { sends[index].preFader = true }
                    else if mode == "post" { sends[index].preFader = false }
                    else { sends[index].gainDB = Double(mode) ?? 0 }
                } else { sends.append(Send(busID: busID, gainDB: Double(mode) ?? 0, preFader: mode == "pre")) }
            }
            if kind == "strip", let index = s.strips.firstIndex(where: { $0.id == id }) { mutate(&s.strips[index].sends) }
            if kind == "bus", let index = s.buses.firstIndex(where: { $0.id == id }) { mutate(&s.buses[index].sends) }
        }
    }
    private func matrixRow(id: String, name: String, kind: String, color: Color) -> some View {
        HStack(spacing: 0) {
            HStack { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3, height: 20); Text(name).font(.system(size: 12)); Spacer(); Text(kind.uppercased()).font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary) }.frame(width: 210).padding(.trailing, 0)
            ForEach(store.session.buses) { bus in
                let connection = send(kind: kind, id: id, busID: bus.id)
                let isExcluded = kind == "strip" && bus.excludedStripID == id
                Button { patch(kind: kind, id: id, busID: bus.id, mode: "toggle") } label: {
                    VStack(spacing: 3) {
                        Image(systemName: kind == "bus" && id == bus.id ? "minus" : isExcluded ? "nosign" : connection == nil ? "plus" : "circle.fill").font(.system(size: 12)).foregroundStyle(isExcluded ? .orange : connection == nil ? .white.opacity(0.16) : color)
                        if let connection, !isExcluded { Text(connection.gainDB <= -90 ? "OFF" : "\(connection.preFader ? "PRE" : "POST") \(Int(connection.gainDB))").font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary) }
                    }.frame(width: 98, height: 48).background(connection == nil ? .clear : color.opacity(0.06)).overlay(Rectangle().stroke(DeskStyle.line, lineWidth: 0.5))
                }.buttonStyle(.plain).disabled(kind == "bus" && id == bus.id)
                    .contextMenu {
                        if kind == "strip" { Button("Pre-fader") { patch(kind: kind,id: id,busID: bus.id,mode: "pre") }; Button("Post-fader") { patch(kind: kind,id: id,busID: bus.id,mode: "post") } }
                        ForEach([0,-6,-12,-24,-90], id: \.self) { gain in Button(gain == -90 ? "Send off" : "\(gain) dB") { patch(kind: kind,id: id,busID: bus.id,mode: String(gain)) } }
                    }
            }
        }.padding(.horizontal, 16)
    }
}
struct AddRouteView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) private var dismiss
    @State private var kind = "bus"
    @State private var sourceID = ""
    @State private var deviceUID = ""
    @State private var left = 0
    @State private var right = 1
    @State private var stereo = true
    @State private var preFader = false
    private var outputs: [String] { store.devices.first { $0.uid == deviceUID }?.outputs ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(title: "Patch an output")
            Form {
                Picker("Source type", selection: $kind) { Text("Bus mix").tag("bus"); Text("Direct channel").tag("strip") }.onChange(of: kind) { _,_ in sourceID = "" }
                Picker("Source", selection: $sourceID) { Text("Choose source").tag(""); if kind == "bus" { ForEach(store.session.buses) { Text($0.name).tag($0.id) } } else { ForEach(store.session.strips) { Text($0.name).tag($0.id) } } }
                if kind == "strip" { Toggle("Before the channel fader", isOn: $preFader) }
                Picker("Destination", selection: $deviceUID) { Text("Choose output").tag(""); ForEach(store.devices.filter { !$0.outputs.isEmpty }) { Text($0.name).tag($0.uid) } }.onChange(of: deviceUID) { _,_ in left = 0; right = 1; stereo = outputs.count > 1 }
                Toggle("Stereo pair", isOn: $stereo).disabled(outputs.count < 2)
                Picker(stereo ? "Left channel" : "Channel", selection: $left) { ForEach(outputs.indices, id: \.self) { Text("\($0+1) · \(outputs[$0])").tag($0) } }
                if stereo { Picker("Right channel", selection: $right) { ForEach(outputs.indices, id: \.self) { Text("\($0+1) · \(outputs[$0])").tag($0) } } }
            }.formStyle(.grouped)
            HStack { Button("Cancel") { dismiss() }; Spacer(); Button("Connect") { store.edit { s in var route = OutputRoute(sourceKind: kind, sourceID: sourceID, destinationUID: deviceUID, channels: stereo ? [left,right] : [left]); route.preFader = preFader; s.routes.append(route) }; dismiss() }.buttonStyle(.borderedProminent).disabled(sourceID.isEmpty || outputs.isEmpty || (stereo && left == right)) }
        }.padding(24).frame(width: 480, height: 430)
    }
}

struct VirtualDevicesView: View {
    @EnvironmentObject var store: DeskStore
    @State private var name = "Desk Call"
    @State private var channelCount = 2
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionTitle(title: "Virtual devices", subtitle: "Give every application its own named audio connection.")
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("CREATE A DEVICE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(DeskStyle.accent)
                        TextField("Device name", text: $name).textFieldStyle(.roundedBorder)
                        Picker("Channels", selection: $channelCount) { ForEach(1...64, id: \.self) { Text($0 == 2 ? "2 · Stereo" : "\($0) channels").tag($0) } }
                        HStack { Button("Recording preset") { name = "Desk Recording"; channelCount = 16 }; Spacer(); Button("Create") { store.createDevice(name, channels: channelCount) }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                        Divider()
                        Label("48 kHz · Persistent device names", systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                        Text("Select the device as a microphone/input in Zoom, Logic, or OBS. Select it as the application's speaker/output to bring its return audio into the desk.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.padding(24).frame(width: 380).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 16) {
                        Text("CONNECT YOUR MIX").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                        Label("1. Create a named device", systemImage: "waveform.path")
                        Label("2. Patch a bus to its output channels", systemImage: "square.grid.3x3")
                        Label("3. Choose it as an input in your app", systemImage: "app.connected.to.app.below.fill")
                        Text("A virtual device is silent until you patch audio to it. Channel counts are fixed; create a new device to change them.").font(.caption).foregroundStyle(.secondary)
                    }.font(.system(size: 13)).padding(24)
                }
                if store.virtualDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("No Mixing Desk devices found").font(.headline)
                        Text("If the driver is not installed, run scripts/build.sh, then sudo scripts/install-driver.sh from the project and reboot. Your existing BlackHole devices are available independently.").font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10))
                }
                ForEach(store.virtualDevices) { device in VirtualDeviceRow(device: device) }
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
private struct VirtualDeviceRow: View {
    @EnvironmentObject var store: DeskStore
    let device: VirtualDevice
    @State private var name = ""
    var body: some View {
        HStack(spacing: 20) {
            Image(systemName: "waveform.path").font(.title2).foregroundStyle(DeskStyle.accent)
            TextField("Name", text: $name).textFieldStyle(.plain).font(.headline).frame(minWidth: 100, maxWidth: 230)
            Text("\(device.channels) IN / \(device.channels) OUT").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
            Text("\(device.clients) clients").font(.caption).foregroundStyle(.secondary)
            Button("Rename") { store.renameDevice(device, name: name) }.disabled(name == device.name || name.isEmpty)
            Button("Remove", role: .destructive) { store.deleteDevice(device) }.disabled(device.clients > 0)
        }.padding(20).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10)).onAppear { name = device.name }.onChange(of: device.name) { _,next in name = next }
    }
}

struct SetupView: View {
    @Environment(\.deskCompact) private var compact
    @EnvironmentObject var store: DeskStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SectionTitle(title: "Audio setup", subtitle: "One shared timeline. Independent mixes for every destination.")
                (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14)) : AnyLayout(HStackLayout(alignment: .top, spacing: 20))) {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("ENGINE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(DeskStyle.accent)
                        TextField("Session name", text: $store.session.name)
                        Picker("Headphones / clock master", selection: Binding(get: { store.session.monitorDeviceUID }, set: { store.chooseMonitor($0) })) {
                            Text("Choose output device").tag("")
                            ForEach(store.devices.filter { !$0.outputs.isEmpty && !$0.uid.hasPrefix("local.mixingdesk.virtual.") }) { Text($0.name).tag($0.uid) }
                            if !store.session.monitorDeviceUID.isEmpty && !store.devices.contains(where: { $0.uid == store.session.monitorDeviceUID }) { Text("Saved output · offline").tag(store.session.monitorDeviceUID) }
                        }
                        Picker("Buffer", selection: $store.session.bufferFrames) { ForEach([32,64,128,256,512,1024], id: \.self) { Text("\($0) samples · \(String(format: "%.2f", Double($0)/48)) ms per buffer").tag($0) } }
                        Text("Use Quad Cortex as the clock master for your headphones. Other devices are drift-corrected. Smaller buffers reduce delay but demand more processing time.").font(.caption).foregroundStyle(.secondary)
                        Picker("Monitoring", selection: $store.session.monitoringMode) { Text("Mixer Monitoring").tag("mixer"); Text("Direct Guitar Monitoring").tag("directGuitar") }
                        if store.running && !store.clockMembers.isEmpty {
                            Divider()
                            Text("SYNCHRONIZATION VERIFIED AT START").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            ForEach(store.clockMembers) { member in
                                HStack {
                                    Text(member.name).lineLimit(1)
                                    Spacer()
                                    Text(member.corrected ? "Drift correction on" : "Clock source").foregroundStyle(.green)
                                }.font(.caption)
                            }
                        }
                    }.padding(24).frame(maxWidth: .infinity).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 15) {
                        Text(store.session.monitoringMode == "mixer" ? "MIXER MONITORING" : "DIRECT GUITAR MONITORING").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(DeskStyle.accent)
                        Text(store.session.monitoringMode == "mixer" ? "Your whole headphone mix passes through the desk." : "Hear the guitar directly from the Quad Cortex.").font(.title3.weight(.medium))
                        Text(store.session.monitoringMode == "mixer" ? "On the Quad Cortex, send the intended guitar signal to USB and disable its duplicate direct path to your headphones. Keep the computer's USB playback routed to the headphone output." : "Keep the Quad Cortex's direct guitar path to your headphones enabled. Strips marked Guitar are removed from the software Monitor bus, while their call, stream, and recording feeds stay active.").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("The desk cannot change Quad Cortex hardware routing. Hearing both paths causes doubled audio or phase effects.").font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text("Latency is an estimate from buffer and device reports. Actual USB and converter delay must be measured with a loopback test.").font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth: .infinity).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 12))
                }
                HStack { Text("AVAILABLE DEVICES").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary); Spacer(); Button("Refresh", action: store.refreshDiscovery) }
                ForEach(store.devices) { device in
                    HStack {
                        Image(systemName: device.uid.hasPrefix("local.mixingdesk") ? "waveform.path" : "hifispeaker").foregroundStyle(DeskStyle.accent).frame(width: 26)
                        VStack(alignment: .leading, spacing: 4) { Text(device.name).font(.system(size: 13, weight: .medium)); Text(device.uid).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary).textSelection(.enabled) }
                        Spacer()
                        Text("\(device.inputs.count) inputs  ·  \(device.outputs.count) outputs").font(.caption).foregroundStyle(.secondary)
                        Text(device.supports48k ? "48 kHz" : "Check rate").font(.system(size: 10, design: .monospaced)).foregroundStyle(device.supports48k ? .green : .orange).frame(width: 75)
                    }.padding(16).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                if store.devices.isEmpty { ContentUnavailableView("No audio devices available", systemImage: "cable.connector.slash", description: Text("Check device connections and macOS audio access, then refresh.")) }
            }.padding(26)
        }
    }
}

import SwiftUI
import DeskModels

struct SetupGuide: View {
    @EnvironmentObject var store: DeskStore
    @State private var step = 0
    private let steps = ["Output", "Sources", "Virtual devices", "Ready"]
    private var output: Device? { store.devices.first { $0.uid == store.session.monitorDeviceUID && !$0.outputs.isEmpty && $0.supports48k } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle(title: "Set up your desk", subtitle: "Choose what you hear and where each source goes.")
            HStack {
                ForEach(steps.indices, id: \.self) { index in
                    Text("\(index + 1). \(steps[index])")
                        .font(.system(size: 12, weight: index == step ? .bold : .regular))
                        .foregroundStyle(index == step ? DeskStyle.accent : .secondary)
                    if index < steps.count - 1 { Spacer() }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case 0: outputStep
                    case 1: sourcesStep
                    case 2: virtualStep
                    default: reviewStep
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
            Divider()
            HStack {
                Button("Finish later") { store.saveLastSession(); store.showingSetupGuide = false }
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                if step < 3 {
                    Button("Continue") { step += 1 }.buttonStyle(.borderedProminent).disabled(step == 0 && output == nil)
                } else {
                    Button("Save without starting") { finish(start: false) }
                    Button("Start Audio") { finish(start: true) }.buttonStyle(.borderedProminent).disabled(output == nil || store.wantsRunning)
                }
            }
        }
        .padding(28).frame(width: 650, height: 570)
        .background(DeskStyle.background).tint(DeskStyle.accent)
        .onChange(of: store.session) { _, _ in store.apply() }
        .alert("Mixing Desk", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    private var outputStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Where do you want to listen?").font(.title2.weight(.semibold))
            Text("Use headphones or an audio interface. This device also supplies the clock for your mix. Audio stays stopped until you choose Start Audio.")
            Picker("Output", selection: Binding(get: { store.session.monitorDeviceUID }, set: store.chooseMonitor)) {
                Text("Choose an output").tag("")
                ForEach(store.devices.filter { !$0.outputs.isEmpty && $0.supports48k && !$0.uid.hasPrefix("local.mixingdesk.virtual.") }) { device in
                    Text(device.name).tag(device.uid)
                }
                if output == nil && !store.session.monitorDeviceUID.isEmpty { Text("Saved output · unavailable").tag(store.session.monitorDeviceUID) }
            }
            Text("Your Monitor bus uses output channels 1/2 by default. Change its output patch if your headphones use different channels. Other rates are not supported: the desk runs at 48 kHz.").font(.callout).foregroundStyle(.secondary)
            Text("If this output disconnects, the desk stops and keeps your routing. It never switches to speakers automatically.").font(.callout).foregroundStyle(.secondary)
            Button("Refresh devices", action: store.refreshDiscovery)
        }
    }

    private var sourcesStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your sources").font(.title2.weight(.semibold))
            Text("Leave sources you do not need unassigned. You can add instrument channels and edit individual input channels on the desk later.")
            ForEach($store.session.strips) { $strip in
                VStack(alignment: .leading, spacing: 6) {
                    Text(strip.name).font(.headline)
                    if strip.source.kind == "application" {
                        Picker("Application", selection: $strip.source.bundleID) {
                            Text("Unassigned").tag("")
                            ForEach(store.apps) { Text($0.name).tag($0.bundleID) }
                            if !strip.source.bundleID.isEmpty && !store.apps.contains(where: { $0.bundleID == strip.source.bundleID }) { Text("Saved application · offline").tag(strip.source.bundleID) }
                        }
                    } else {
                        Picker("Input", selection: Binding(get: { strip.source.deviceUID }, set: { uid in
                            strip.source.deviceUID = uid
                            if let device = store.devices.first(where: { $0.uid == uid }), strip.source.channels.contains(where: { $0 >= device.inputs.count }) { strip.source.channels = [0] }
                        })) {
                            Text("Unassigned").tag("")
                            ForEach(store.devices.filter { !$0.inputs.isEmpty && $0.supports48k }) { Text($0.name).tag($0.uid) }
                            if !strip.source.deviceUID.isEmpty && !store.devices.contains(where: { $0.uid == strip.source.deviceUID }) { Text("Saved input · offline").tag(strip.source.deviceUID) }
                        }
                        Text("Input channels: \(strip.source.channels.map { String($0 + 1) }.joined(separator: ", ")). Change these in Channel Settings.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Play audio in an app to make it appear here. Choose each application once. Its normal playback is muted while captured; listen through the Monitor bus.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var virtualStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Send a mix to another app").font(.title2.weight(.semibold))
            Text("Virtual devices let your call, streaming, or recording app hear a desk bus as a microphone. You can skip this step for headphone mixing.")
            DriverStatusView()
            Text("After setup, open Virtual Devices and create a stereo Desk Call or Desk Stream. In Patching, connect the matching bus to channels 1/2 of that device, then select it as an input in the receiving app.").font(.callout)
            Text("The Call bus excludes Call Return by default, so callers do not hear themselves. Use either an application capture or a virtual return for the same app, never both.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ready when you are").font(.title2.weight(.semibold))
            LabeledContent("Output", value: output?.name ?? "Choose an available output")
            LabeledContent("Engine", value: "48 kHz · \(store.session.bufferFrames) samples")
            Text("Start Audio requests microphone access; macOS also controls access to captured application audio. If access is denied, enable Mixing Desk under System Settings → Privacy & Security → Microphone and Screen & System Audio Recording, then try again. Setting names vary by macOS version.")
            Text("Begin at a low headphone level. Disable duplicate direct monitoring on your interface if you monitor that source through the desk.").font(.callout).foregroundStyle(.secondary)
            Text("Closing the window leaves the menu-bar mixer running. Use Stop Audio or Quit Mixing Desk to end mixing.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func finish(start: Bool) {
        store.apply(); store.saveLastSession(); store.showingSetupGuide = false
        if start { store.toggleAudio() }
    }
}

struct DriverStatusView: View {
    @EnvironmentObject var store: DeskStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(store.driverStatus.ready ? "Virtual audio ready" : "Optional virtual audio", systemImage: store.driverStatus.ready ? "checkmark.circle" : "info.circle")
                .font(.headline)
            Text(store.driverStatus.message).font(.callout).foregroundStyle(.secondary)
            if store.driverStatus.installedBuild > 0 || store.driverStatus.loadedBuild > 0 {
                Text("Installed build \(store.driverStatus.installedBuild) · Loaded build \(store.driverStatus.loadedBuild)").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 10))
    }
}

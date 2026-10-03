import SwiftUI
import DeskModels
import DeskAudio

struct InsertButton: View {
    let inserts: [InsertSlot]
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                Text(inserts.isEmpty ? "Add Insert" : "Inserts · \(inserts.count)")
                Spacer()
                if !inserts.isEmpty { Circle().fill(inserts.allSatisfy(\.bypassed) ? Color.gray : DeskStyle.accent).frame(width: 5, height: 5) }
            }.font(.system(size: 10, weight: .medium)).padding(8)
                .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).foregroundStyle(DeskStyle.accent)
    }
}

struct InsertEditor: View {
    @Environment(\.deskCompact) private var compact
    @EnvironmentObject var store: DeskStore
    @State private var browsingPlugins = false
    @Environment(\.dismiss) private var dismiss
    @Binding var inserts: [InsertSlot]
    let ownerName: String
    let isBus: Bool
    @State private var selectedID = ""
    private var selection: Int? { inserts.firstIndex { $0.id == selectedID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                SectionTitle(title: "\(ownerName) · Inserts", subtitle: isBus ? "Applied before the bus master fader." : "Applied after input trim, before the fader and all sends.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("SIGNAL ORDER").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(Array(inserts.enumerated()), id: \.element.id) { index, insert in
                        Button { selectedID = insert.id } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(index + 1)  \(insert.displayName)").lineLimit(2).font(.system(size: 12, weight: .semibold))
                                Text(insert.bypassed ? "Bypassed" : "Active").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .background(selectedID == insert.id ? DeskStyle.accent.opacity(0.12) : DeskStyle.panel, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    Menu("Add Insert") {
                        Button("Desk EQ") { let insert = InsertSlot.equalizer(); inserts.append(insert); selectedID = insert.id }
                        Button("VST3 / AUv2 Plugin…") { browsingPlugins = true }
                    }.disabled(inserts.count >= 4)
                    if let index = selection {
                        HStack {
                            Button { inserts.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move insert earlier")
                            Button { inserts.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index + 1 == inserts.count).help("Move insert later")
                            Spacer()
                            Button("Remove", role: .destructive) { inserts.remove(at: index); selectedID = inserts.first?.id ?? "" }
                        }.controlSize(.small)
                    }
                    Spacer()
                    Text("Up to four inserts.\nChanges are saved with your desk.").font(.caption).foregroundStyle(.secondary)
                }.frame(width: compact ? 150 : 175)
                if let index = selection {
                    ScrollView {
                        if inserts[index].isPlugin { PluginInsertView(slot: $inserts[index]) }
                        else { EqualizerEditor(slot: $inserts[index]) }
                    }.frame(maxWidth: .infinity)
                }
                else { ContentUnavailableView("Add an insert", systemImage: "slider.horizontal.3", description: Text("Choose Desk EQ or an installed VST3 or AUv2 effect.")).frame(maxWidth: .infinity) }
            }
        }.padding(compact ? 18 : 24).frame(width: compact ? 730 : 860, height: compact ? 490 : 590).background(DeskStyle.background).tint(DeskStyle.accent)
            .onAppear { selectedID = inserts.first?.id ?? "" }
            .sheet(isPresented: $browsingPlugins) {
                PluginBrowser { plugin in
                    let insert = plugin.format == "vst3" ? InsertSlot.vst3(identifier: plugin.identifier, name: plugin.name) : InsertSlot.audioUnit(identifier: plugin.identifier, name: plugin.name)
                    inserts.append(insert); selectedID = insert.id
                }
            }
    }
}

private struct EqualizerEditor: View {
    @Environment(\.deskCompact) private var compact
    @Binding var slot: InsertSlot
    private func binding(_ key: WritableKeyPath<EQSettings, Double>) -> Binding<Double> {
        Binding(get: { slot.eq[keyPath: key] }, set: { value in var settings = slot.eq; settings[keyPath: key] = value; slot.eq = settings })
    }
    private func frequency(_ key: WritableKeyPath<EQSettings, Double>) -> Binding<Double> {
        let hz = binding(key)
        let defaultHz = EQSettings()[keyPath: key]
        return Binding(get: { log10(hz.wrappedValue) }, set: { hz.wrappedValue = $0 == log10(defaultHz) ? defaultHz : min(20000, max(20, pow(10, $0))) })
    }
    private func hz(_ frequency: Double) -> String { frequency >= 1000 ? String(format: "%.2f kHz", frequency/1000) : String(format: "%.0f Hz", frequency) }
    private var response: [Double] {
        let p = slot.eq
        let values = ["lowFrequency": p.lowFrequency, "lowGain": p.lowGain, "midFrequency": p.midFrequency, "midGain": p.midGain, "midQ": p.midQ, "highFrequency": p.highFrequency, "highGain": p.highGain, "outputGain": p.outputGain]
        return MDAudioController.equalizerResponse(values.mapValues { NSNumber(value: $0) }).map(\.doubleValue)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DESK EQ").font(.system(size: 18, weight: .bold, design: .rounded)).tracking(2)
                    Text("Three bands · Stereo linked · No added buffering").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset EQ") { slot.eq = EQSettings() }
                Toggle("Bypass", isOn: $slot.bypassed).toggleStyle(.switch).fixedSize()
            }
            EQResponseGraph(points: response, bypassed: slot.bypassed).frame(height: compact ? 125 : 175)
            HStack(alignment: .top, spacing: 14) {
                band("LOW SHELF", frequency: \.lowFrequency, gain: \.lowGain, defaultHz: 120)
                band("MID BELL", frequency: \.midFrequency, gain: \.midGain, defaultHz: 1000)
                band("HIGH SHELF", frequency: \.highFrequency, gain: \.highGain, defaultHz: 8000)
            }
            HStack(spacing: 14) {
                Text("OUTPUT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ResettableSlider(value: binding(\.outputGain), range: -18...18, label: "EQ output gain")
                Text(String(format: "%+.1f dB", slot.eq.outputGain)).font(.system(.caption, design: .monospaced)).frame(width: 65, alignment: .trailing)
            }
            Text("Double-click any slider to restore its default. Bypass lets you compare the original signal.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func band(_ name: String, frequency key: WritableKeyPath<EQSettings, Double>, gain: WritableKeyPath<EQSettings, Double>, defaultHz: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(name).font(.system(size: 10, weight: .bold)).foregroundStyle(DeskStyle.accent)
            Text(hz(slot.eq[keyPath: key])).font(.system(size: 12, design: .monospaced))
            ResettableSlider(value: frequency(key), range: log10(20)...log10(20000), defaultValue: log10(defaultHz), label: "\(name) frequency", defaultDescription: hz(defaultHz))
            Text(String(format: "%+.1f dB", slot.eq[keyPath: gain])).font(.system(size: 12, design: .monospaced))
            ResettableSlider(value: binding(gain), range: -18...18, label: "\(name) gain")
            if key == \.midFrequency {
                HStack { Text("Q"); Spacer(); Text(String(format: "%.2f", slot.eq.midQ)) }.font(.system(size: 11, design: .monospaced))
                ResettableSlider(value: binding(\.midQ), range: 0.1...10, defaultValue: 1, label: "Mid Q", defaultDescription: "1.00")
            } else { Text("Broad tone shaping").font(.system(size: 9)).foregroundStyle(.secondary).padding(.top, 3) }
        }.padding(12).frame(maxWidth: .infinity, minHeight: 186, alignment: .topLeading).background(DeskStyle.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EQResponseGraph: View {
    let points: [Double]
    let bypassed: Bool
    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 34, y: 14, width: size.width - 48, height: size.height - 38)
            let limit = max(24, ceil((points.map(abs).max() ?? 0) / 6) * 6)
            func y(_ db: Double) -> CGFloat { plot.midY - CGFloat(db / limit) * plot.height / 2 }
            for db in [-limit, 0, limit] {
                var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y(db))); line.addLine(to: CGPoint(x: plot.maxX, y: y(db)))
                context.stroke(line, with: .color(.white.opacity(db == 0 ? 0.25 : 0.08)), lineWidth: 1)
                context.draw(Text(String(format: "%+.0f", db)).font(.system(size: 9, design: .monospaced)).foregroundColor(.gray), at: CGPoint(x: 15, y: y(db)))
            }
            for frequency in [20.0, 100, 1000, 10000, 20000] {
                let x = plot.minX + CGFloat(log10(frequency / 20) / 3) * plot.width
                var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(.white.opacity(0.08)), lineWidth: 1)
                context.draw(Text(frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))").font(.system(size: 9, design: .monospaced)).foregroundColor(.gray), at: CGPoint(x: x, y: size.height - 10))
            }
            var curve = Path()
            for (index, value) in points.enumerated() {
                let point = CGPoint(x: plot.minX + CGFloat(index) / CGFloat(max(1, points.count - 1)) * plot.width, y: y(bypassed ? 0 : value))
                if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            context.stroke(curve, with: .color(bypassed ? .gray : DeskStyle.accent), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round))
        }.background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(bypassed ? "EQ bypassed: flat response" : "EQ frequency response, 20 Hz to 20 kHz")
    }
}

import SwiftUI

struct ChannelProtectionActivity: View {
    @ObservedObject var readings: DeskMeters
    let ownerID: String
    let enabled: Bool
    var body: some View {
        let value = readings.value.meter(ownerID: ownerID, isBus: false)
        let active = value.reductionDB > 0.05
        Text(enabled && active ? String(format: "LIMIT −%.1f dB", value.reductionDB) : enabled ? "PROTECT" : "BYPASS")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(enabled && active ? DeskStyle.accent : Color.secondary)
            .help("Channel sample-peak protection: −1 dBFS, 48-sample lookahead, 100 ms release. LIMIT shows successful gain reduction, separately from red overload warnings. Pre- and post-fader paths are protected independently.")
    }
}
struct OutputProtectionIndicator: View {
    @ObservedObject var readings: DeskMeters
    let enabled: Bool
    @State private var showingGroups = false
    var body: some View {
        let active = readings.value.outputs.filter { $0.meter.reductionDB > 0.05 }
        let reduction = active.map { $0.meter.reductionDB }.max() ?? 0
        let names = active.flatMap(\.destinations).joined(separator: ", ")
        Button { showingGroups.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: enabled ? "shield.lefthalf.filled" : "shield.slash")
                Text(!enabled ? "Output protection bypassed" : reduction > 0.05 ? String(format: "OUTPUT LIMIT −%.1f dB", reduction) : "Output protection")
                if readings.value.outputs.contains(where: { $0.meter.clip }) { Text("OVER").foregroundStyle(.red).help("Latched output overload. Reset All Meters clears it.") }
                if enabled && !names.isEmpty { Text(names).lineLimit(1).truncationMode(.tail).frame(maxWidth: 260) }
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(enabled && reduction > 0.05 ? DeskStyle.accent : Color.secondary)
        }.buttonStyle(.plain)
            .help(names.isEmpty ? "Final −1 dBFS sample-peak protection follows the complete output sum and route gains. Adds 48 samples; stereo and overlapping pairs share gain reduction. Click for destinations." : "Limiting: \(names)")
            .popover(isPresented: $showingGroups) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(enabled ? "Final output protection" : "Final output protection bypassed").font(.headline)
                    Text("−1 dBFS · 48 samples lookahead · 100 ms release").font(.caption).foregroundStyle(.secondary)
                    if readings.value.outputs.isEmpty { Text("No active output destinations.").font(.caption) }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(readings.value.outputs, id: \.meter.id) { group in
                                HStack {
                                    Text(group.destinations.joined(separator: " / ")).lineLimit(3)
                                    Spacer()
                                    Text(group.meter.clip ? "OVER" : enabled && group.meter.reductionDB > 0.05 ? String(format: "LIMIT −%.1f dB", group.meter.reductionDB) : "Ready")
                                        .foregroundStyle(group.meter.clip ? Color.red : DeskStyle.accent)
                                }.font(.caption)
                            }
                        }
                    }.frame(height: min(240, CGFloat(readings.value.outputs.count)*42))
                    Text("Bus meters precede this stage. Sample peaks are protected; intersample true peaks and existing input/plugin distortion are not repaired.").font(.caption).foregroundStyle(.secondary)
                }.padding(18).frame(width: 390)
            }
    }
}

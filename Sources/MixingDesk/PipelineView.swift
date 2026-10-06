import SwiftUI
import DeskModels

private enum PipelineEditor: Identifiable {
    case channel(ChannelStrip), bus(Bus), inserts(PipelineNodeID), connection(PipelineEdge), output(OutputRoute), addOutput
    var id: String {
        switch self {
        case .channel(let s): return "channel:"+s.id
        case .bus(let b): return "bus:"+b.id
        case .inserts(let n): return "inserts:"+n.key
        case .connection(let e): return "connection:\(e.id)"
        case .output(let r): return "output:"+r.id
        case .addOutput: return "addOutput"
        }
    }
}
struct PipelineView: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.deskCompact) private var compact
    @State private var positions: [String: PipelinePosition] = [:]
    @State private var pan = CGSize.zero
    @State private var zoom: CGFloat = 1
    @State private var initialPan: CGSize?
    @State private var moving: (String, PipelinePosition)?
    @State private var selectedNode: PipelineNodeID?
    @State private var selectedConnection: PipelineConnection?
    @State private var connecting: PipelineNodeID?
    @State private var draggingConnection = false
    @State private var cancelledConnectionDrag = false
    @State private var pointer: CGPoint?
    @State private var editor: PipelineEditor?
    @State private var viewport = CGSize.zero
    @FocusState private var focused: Bool
    private var graph: PipelineGraph { PipelineGraph(store.session) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    DeskStyle.background
                    PipelineNavigation(scroll: { delta, point, magnifying in
                        if magnifying { setZoom(zoom * exp(delta.height * 0.01), at: point) }
                        else { pan.width += delta.width; pan.height += delta.height }
                    }, magnify: { amount, point in setZoom(zoom * (1 + amount), at: point) })
                    canvas
                        .scaleEffect(zoom, anchor: .topLeading)
                        .offset(pan)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped().contentShape(Rectangle()).coordinateSpace(name: "pipelineViewport")
                .onAppear { viewport = geometry.size; synchronizePositions(); frameInitialView() }
                .onChange(of: geometry.size) { _, next in viewport = next }
            }
            legend
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onExitCommand { cancelledConnectionDrag = draggingConnection; cancelConnection(); selectedConnection = nil; focused = true }
        .onDeleteCommand { removeSelection() }
        .onChange(of: graph.nodes) { _, _ in synchronizePositions() }
        .onChange(of: store.session.pipelineLayout) { _, _ in synchronizePositions() }
        .onChange(of: store.sessionGeneration) { _, _ in
            positions = [:]; selectedNode = nil; selectedConnection = nil; editor = nil; cancelConnection(); synchronizePositions(); frameInitialView()
        }
        .sheet(item: $editor) { item in editorView(item).environmentObject(store) }
    }
    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { title; Spacer(); creationControls; Divider().frame(height: 20); navigationControls }
            VStack(alignment: .leading, spacing: 10) {
                HStack { title; Spacer(); creationControls }
                HStack { navigationControls; Spacer() }
            }
        }.padding(.horizontal, compact ? 16 : 24).padding(.vertical, 12).background(DeskStyle.panel.opacity(0.5))
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Signal pipeline").font(.system(size: compact ? 18 : 22, weight: .semibold))
            Text(connecting == nil ? "Connect your sources, mixes, and outputs." : "Choose a destination · Escape to cancel")
                .font(.system(size: 11)).foregroundStyle(connecting == nil ? .secondary : DeskStyle.accent)
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var creationControls: some View {
        HStack(spacing: 9) {
            Menu {
                Button("Channel") { store.addStrip(withDisabledSends: false) }.disabled(store.session.strips.count >= 64)
                Button("Bus") { store.addBus() }.disabled(store.session.buses.count >= 16)
                Button("Output Device…") { editor = .addOutput }
            } label: { Label("Add", systemImage: "plus") }
            Menu {
                ForEach(graph.edges) { edge in Button(edgeName(edge)) { select(edge) } }
                if graph.edges.isEmpty { Text("No connections yet") }
            } label: { Label("Connections", systemImage: "point.3.connected.trianglepath.dotted") }
            .help("Inspect and edit a connection without dragging.")
        }.fixedSize()
    }
    private var navigationControls: some View {
        HStack(spacing: 9) {
            Button(action: store.undoRouting) { Image(systemName: "arrow.uturn.backward") }
                .disabled(store.routingHistory.undoName == nil || editor != nil).help("Undo \(store.routingHistory.undoName ?? "routing edit")")
                .keyboardShortcut("z", modifiers: .command).accessibilityLabel("Undo routing")
            Button(action: store.redoRouting) { Image(systemName: "arrow.uturn.forward") }
                .disabled(store.routingHistory.redoName == nil || editor != nil).help("Redo \(store.routingHistory.redoName ?? "routing edit")")
                .keyboardShortcut("z", modifiers: [.command, .shift]).accessibilityLabel("Redo routing")
            Button { setZoom(zoom / 1.2, at: CGPoint(x: viewport.width/2, y: viewport.height/2)) } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
            Text("\(Int(zoom * 100))%").font(.system(size: 10, design: .monospaced)).frame(width: 34)
            Button { setZoom(zoom * 1.2, at: CGPoint(x: viewport.width/2, y: viewport.height/2)) } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
            Button("Fit All", action: fit)
            Button("Auto Arrange") { positions = graph.arranged(); persistPositions(); frameInitialView() }
        }.controlSize(.small).fixedSize()
    }
    private var canvas: some View {
        let extent = CGSize(width: max(2500, (positions.values.map(\.x).max() ?? 0) + 600), height: max(1600, (positions.values.map(\.y).max() ?? 0) + 600))
        let snapshot = graph
        let trace = selectedNode.map { snapshot.trace(from: $0, in: store.session) }
        return ZStack(alignment: .topLeading) {
            PipelineWires(graph: snapshot, session: store.session, positions: positions, trace: trace, selected: selectedConnection, connecting: connecting, pointer: pointer)
                .frame(width: extent.width, height: extent.height)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    focused = true
                    if let edge = snapshot.edges.reversed().first(where: { edge in
                        guard let a = positions[edge.source.key], let b = positions[edge.destination.key] else { return false }
                        return PipelineGeometry.hit(point, from: PipelineGeometry.port(a, output: true), to: PipelineGeometry.port(b, output: false), tolerance: 7/zoom)
                    }) { select(edge) }
                    else { selectedConnection = nil; selectedNode = nil; cancelConnection() }
                }
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("pipelineViewport"))
                    .onChanged { value in
                        if initialPan == nil { initialPan = pan }
                        pan = CGSize(width: initialPan!.width + value.translation.width, height: initialPan!.height + value.translation.height)
                    }.onEnded { _ in initialPan = nil })
            ForEach(snapshot.nodes, id: \.self) { node in
                if let p = positions[node.key] {
                    nodeCard(node)
                        .overlay(alignment: .topLeading) {
                            if node.kind != .strip { port(node, output: false).position(x: 0, y: PipelineGeometry.portY) }
                        }
                        .overlay(alignment: .topLeading) {
                            if node.kind != .output { port(node, output: true).position(x: PipelineGeometry.card.width, y: PipelineGeometry.portY) }
                        }
                        .position(x: p.x + PipelineGeometry.card.width/2, y: p.y + PipelineGeometry.card.height/2)
                }
            }
        }
        .frame(width: extent.width, height: extent.height, alignment: .topLeading)
        .coordinateSpace(name: "pipelineGraph")
        .background(Color.clear)
        .onContinuousHover { phase in if case .active(let location) = phase, connecting != nil { pointer = location } }
    }
    private func metersVisible(_ node: PipelineNodeID) -> Bool {
        guard viewport.width > 0, let p = positions[node.key] else { return false }
        let rect = CGRect(x: p.x*zoom+pan.width, y: p.y*zoom+pan.height,
                          width: PipelineGeometry.card.width*zoom, height: PipelineGeometry.card.height*zoom)
        // Offscreen cards retain their editors and identities, but subscribe to
        // telemetry only near the viewport. Dense desks otherwise re-layout
        // every native field for meter changes on dozens of invisible blocks.
        return rect.intersects(CGRect(origin: .zero, size: viewport).insetBy(dx: -30, dy: -30))
    }
    private func nodeCard(_ node: PipelineNodeID) -> some View {
        PipelineNodeCard(node: node, selected: selectedNode == node, compatible: connecting.map { problem(from: $0, to: node) == nil } ?? false,
                         name: name(node), metersVisible: metersVisible(node), select: { selectedNode = node; selectedConnection = nil; focused = true },
                         configure: { configure(node) }, inserts: { editor = .inserts(node) },
                         move: { translation in
                            if moving?.0 != node.key, let p = positions[node.key] { moving = (node.key, p) }
                            if let original = moving?.1 { positions[node.key] = PipelinePosition(x: max(20, original.x + translation.width), y: max(20, original.y + translation.height)) }
                         }, moved: { moving = nil; persistPositions() }) {
            if node.kind != .output {
                Menu("Connect to…") {
                    ForEach(graph.nodes.filter { $0.kind != .strip }, id: \.self) { target in
                        let reason = problem(from: node, to: target)
                        Button(name(target)) { connect(node, to: target) }.disabled(reason != nil).help(reason ?? "Connect")
                    }
                }
                Button("Settings…") { configure(node) }
                Button("Inserts…") { editor = .inserts(node) }
            } else {
                Button("Use for Monitoring") { store.chooseMonitor(node.rawID) }.disabled(!canMonitor(node))
            }
            Divider()
            Button("Remove \(node.kind == .output ? "Output and Routes" : node.kind == .bus ? "Bus" : "Channel")", role: .destructive) { store.removePipelineNode(node); selectedNode = nil }
                .disabled(node.kind == .bus && store.session.buses.first(where: { $0.id == node.rawID })?.kind == "monitor")
        }
    }
    private func port(_ node: PipelineNodeID, output: Bool) -> some View {
        let canConnect = connecting.map { problem(from: $0, to: node) == nil } ?? false
        return Button {
            focused = true
            if output { connecting = node; pointer = positions[node.key].map { PipelineGeometry.port($0, output: true) } }
            else if let source = connecting { connect(source, to: node) }
        } label: {
            Circle().fill(canConnect ? .green : DeskStyle.elevated).overlay(Circle().stroke(canConnect ? .green : DeskStyle.accent, lineWidth: 2)).frame(width: 13, height: 13).padding(8).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .help(output ? "Drag to connect, or click then choose an input." : connecting.flatMap { problem(from: $0, to: node) } ?? "Input")
        .accessibilityLabel("\(name(node)) \(output ? "output — connect" : "input")")
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("pipelineGraph"))
            .onChanged { value in
                guard output else { return }
                draggingConnection = true
                guard !cancelledConnectionDrag else { return }
                focused = true; connecting = node; pointer = value.location
            }
            .onEnded { value in
                guard output else { return }
                defer { draggingConnection = false; cancelledConnectionDrag = false }
                guard !cancelledConnectionDrag else { cancelConnection(); return }
                if let target = graph.nodes.first(where: { target in
                    guard target.kind != .strip, let p = positions[target.key] else { return false }
                    return CGRect(x: p.x-18, y: p.y, width: PipelineGeometry.card.width+36, height: PipelineGeometry.card.height).contains(value.location)
                }) { connect(node, to: target) } else { cancelConnection() }
            })
    }
    private var legend: some View {
        HStack(spacing: 15) {
            Label("Drag ports to connect", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
            Text("Dashed: off / excluded")
            if selectedNode != nil { Label("Highlighted: selected signal path", systemImage: "arrow.triangle.branch") }
            Spacer(minLength: 0)
            Text("Scroll to pan · pinch to zoom")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 9).background(DeskStyle.panel)
    }
    private func name(_ node: PipelineNodeID) -> String {
        switch node.kind {
        case .strip: return store.session.strips.first { $0.id == node.rawID }?.name ?? "Channel"
        case .bus: return store.session.buses.first { $0.id == node.rawID }?.name ?? "Bus"
        case .output: return store.devices.first { $0.uid == node.rawID }?.name ?? "Saved output · offline"
        }
    }
    private func edgeName(_ edge: PipelineEdge) -> String {
        let channels = edge.channels.isEmpty ? "" : " · Ch \(edge.channels.map { String($0+1) }.joined(separator: "/"))"
        return "\(name(edge.source)) → \(name(edge.destination))\(channels)"
    }
    private func select(_ edge: PipelineEdge) { selectedConnection = edge.id; selectedNode = nil; cancelConnection(); editor = .connection(edge) }
    private func canMonitor(_ node: PipelineNodeID) -> Bool {
        store.devices.contains { $0.uid == node.rawID && $0.supports48k && !$0.outputs.isEmpty && !$0.uid.hasPrefix("local.mixingdesk.virtual.") }
    }
    private func problem(from source: PipelineNodeID, to target: PipelineNodeID) -> String? {
        if source.kind == .output || target.kind == .strip { return "Connect a channel or bus to a bus or output." }
        if target.kind == .bus { return store.sendProblem(from: source, to: target.rawID) }
        guard let device = store.devices.first(where: { $0.uid == target.rawID }), !device.outputs.isEmpty else { return "Reconnect this output before adding a route." }
        return device.supports48k ? nil : "This output does not support 48 kHz."
    }
    private func connect(_ source: PipelineNodeID, to target: PipelineNodeID) {
        defer { cancelConnection() }
        if let reason = problem(from: source, to: target) { store.error = reason; return }
        if target.kind == .bus {
            if let existing = graph.edges.first(where: { $0.id == .send(source, target.rawID) }) { select(existing) }
            else { store.setSend(from: source, to: target.rawID, value: Send(busID: target.rawID)) }
        } else {
            let count = store.devices.first { $0.uid == target.rawID }?.outputs.count ?? 1
            editor = .output(OutputRoute(sourceKind: source.kind.rawValue, sourceID: source.rawID, destinationUID: target.rawID, channels: count > 1 ? [0,1] : [0]))
        }
    }
    private func cancelConnection() { connecting = nil; pointer = nil }
    private func configure(_ node: PipelineNodeID) {
        if let strip = store.session.strips.first(where: { node.kind == .strip && $0.id == node.rawID }) { editor = .channel(strip) }
        else if let bus = store.session.buses.first(where: { node.kind == .bus && $0.id == node.rawID }) { editor = .bus(bus) }
    }
    private func synchronizePositions() {
        let automatic = graph.arranged(), saved = store.session.pipelineLayout?.positions ?? [:]
        let keys = Set(graph.nodes.map(\.key))
        positions = positions.filter { keys.contains($0.key) }
        for node in graph.nodes { if let p = saved[node.key] { positions[node.key] = p } }
        for node in graph.nodes where positions[node.key] == nil {
            guard var candidate = automatic[node.key] else { continue }
            // New blocks must not cover a retained or manually moved block.
            // Discovery/reconnection never enters this path for existing IDs.
            while positions.values.contains(where: {
                abs($0.x-candidate.x) < PipelineGeometry.card.width + 20 && abs($0.y-candidate.y) < PipelineGeometry.card.height + 12
            }) { candidate.y += 250 }
            positions[node.key] = candidate
        }
        if let selectedNode, !graph.nodes.contains(selectedNode) { self.selectedNode = nil }
        if let connecting, !graph.nodes.contains(connecting) { cancelConnection() }
    }
    private func persistPositions() { store.savePipelinePositions(positions) }
    private func setZoom(_ value: CGFloat, at anchor: CGPoint) {
        let next = min(2, max(0.01, value)), factor = next/zoom
        pan = CGSize(width: anchor.x-(anchor.x-pan.width)*factor, height: anchor.y-(anchor.y-pan.height)*factor); zoom = next
    }
    private func fit() {
        guard !positions.isEmpty, viewport.width > 0 else { return }
        let minX = positions.values.map(\.x).min() ?? 0, minY = positions.values.map(\.y).min() ?? 0
        let width = (positions.values.map(\.x).max() ?? 0) - minX + PipelineGeometry.card.width
        let height = (positions.values.map(\.y).max() ?? 0) - minY + PipelineGeometry.card.height
        zoom = max(0.01, min(1, min((viewport.width-70)/width, (viewport.height-60)/height)))
        pan = CGSize(width: (viewport.width-width*zoom)/2-minX*zoom, height: max(30, (viewport.height-height*zoom)/2)-minY*zoom)
    }
    private func frameInitialView() {
        fit()
        // Keep controls readable on small windows and large desks. Fit All is
        // still available as an explicit overview; scrolling reveals the rest.
        if zoom < 0.85 {
            zoom = 1
            pan = CGSize(width: 28 - (positions.values.map(\.x).min() ?? 0) * zoom,
                         height: 24 - (positions.values.map(\.y).min() ?? 0) * zoom)
        }
    }
    private func removeSelection() {
        guard editor == nil, connecting == nil else { return }
        if let selectedConnection { store.disconnect(selectedConnection); self.selectedConnection = nil }
        else if let selectedNode { store.removePipelineNode(selectedNode); self.selectedNode = nil }
    }
    @ViewBuilder private func editorView(_ item: PipelineEditor) -> some View {
        switch item {
        case .channel(let strip): PipelineChannelEditor(strip: strip)
        case .bus(let bus): PipelineBusEditor(bus: bus)
        case .addOutput: PipelineOutputPicker()
        case .output(let route): PipelineConnectionEditor(route: route)
        case .connection(let edge): PipelineConnectionEditor(edge: edge, session: store.session)
        case .inserts(let node):
            InsertEditor(inserts: Binding(get: {
                node.kind == .strip ? store.session.strips.first { $0.id == node.rawID }?.inserts ?? [] : store.session.buses.first { $0.id == node.rawID }?.inserts ?? []
            }, set: { value in store.edit { s in
                if node.kind == .strip, let i = s.strips.firstIndex(where: { $0.id == node.rawID }) { s.strips[i].inserts = value }
                else if let i = s.buses.firstIndex(where: { $0.id == node.rawID }) { s.buses[i].inserts = value }
            } }), ownerName: name(node), isBus: node.kind == .bus)
        }
    }
}

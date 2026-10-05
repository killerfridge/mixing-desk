import SwiftUI
import DeskModels

extension DeskStore {
    /// Validate first. Failed previews, cancelled drags and rejected edits neither
    /// publish an intermediate session nor create undo entries.
    @discardableResult func routeEdit(_ name: String, _ change: (inout Session) throws -> Void) -> Bool {
        do {
            var next = routingGesture?.draft ?? session
            try change(&next)
            _ = try next.validated()
            if routingGesture != nil { routingGesture?.draft = next; return true }
            guard next != session else { return true }
            routingHistory.record(RoutingChange(name, before: session, after: next))
            session = next; apply()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func trackRoutingGesture(_ tracking: Bool, name: String) {
        if tracking { routingGesture = (name, session, session) }
        else if let gesture = routingGesture {
            routingGesture = nil
            routeEdit(gesture.name) { live in
                live = try RoutingChange(gesture.name, before: gesture.before, after: gesture.draft).applying(to: live, backwards: false)
            }
        }
    }
    func undoRouting() {
        do { let next = try routingHistory.undo(session); session = next; apply() }
        catch { self.error = error.localizedDescription }
    }
    func redoRouting() {
        do { let next = try routingHistory.redo(session); session = next; apply() }
        catch { self.error = error.localizedDescription }
    }
    func sendProblem(from source: PipelineNodeID, to busID: String) -> String? {
        do {
            var candidate = session
            let value = candidate.sends(from: source).first { $0.busID == busID } ?? Send(busID: busID)
            try candidate.setSend(from: source, to: busID, value: value)
            _ = try candidate.validated()
            return nil
        } catch { return error.localizedDescription }
    }
    @discardableResult func setSend(from source: PipelineNodeID, to busID: String, value: Send?) -> Bool {
        routeEdit(value == nil ? "Disconnect Send" : "Edit Send") { try $0.setSend(from: source, to: busID, value: value) }
    }
    func patchSend(from source: PipelineNodeID, to busID: String, mode: String) {
        var value = session.sends(from: source).first { $0.busID == busID }
        if mode == "toggle", value != nil { setSend(from: source, to: busID, value: nil); return }
        if value == nil { value = Send(busID: busID) }
        if mode == "pre" { value?.preFader = true }
        else if mode == "post" { value?.preFader = false }
        else if let gain = Double(mode) { value?.gainDB = gain }
        setSend(from: source, to: busID, value: value)
    }
    @discardableResult func configureChannel(_ value: ChannelStrip) -> Bool {
        let source = value.source
        if source.kind == "application", !source.channels.allSatisfy({ (0..<2).contains($0) }) {
            error = "Choose mono or stereo application channels 1 and 2."; return false
        }
        if source.kind == "device", !source.deviceUID.isEmpty {
            if let device = devices.first(where: { $0.uid == source.deviceUID }) {
                guard source.channels.allSatisfy({ device.inputs.indices.contains($0) }) else { error = "Choose available input channels for this device."; return false }
            } else if session.strips.first(where: { $0.id == value.id })?.source != source {
                error = "Reconnect this input before changing its channel mapping."; return false
            }
        }
        return routeEdit("Configure Channel") { s in
            guard let i = s.strips.firstIndex(where: { $0.id == value.id }) else { throw SessionError.invalid("This channel no longer exists.") }
            s.strips[i].name = value.name; s.strips[i].color = value.color
            s.strips[i].role = value.role; s.strips[i].source = value.source
        }
    }
    func outputProblem(_ route: OutputRoute, existing: OutputRoute? = nil) -> String? {
        guard !route.destinationUID.isEmpty else { return "Choose an output device." }
        if let device = devices.first(where: { $0.uid == route.destinationUID }) {
            guard device.supports48k else { return "This output does not support the 48 kHz engine." }
            guard route.channels.allSatisfy({ device.outputs.indices.contains($0) }) else { return "Choose available output channels." }
        } else if existing?.destinationUID != route.destinationUID || existing?.channels != route.channels {
            return "Reconnect this output before changing its channel mapping. Existing offline routes are preserved."
        }
        return nil
    }
    @discardableResult func saveRoute(_ route: OutputRoute) -> Bool {
        let old = session.routes.first { $0.id == route.id }
        if let problem = outputProblem(route, existing: old) { error = problem; return false }
        return routeEdit(old == nil ? "Connect Output" : "Edit Output Route") { s in
            if let index = s.routes.firstIndex(where: { $0.id == route.id }) { s.routes[index] = route }
            else { s.routes.append(route) }
        }
    }
    func disconnect(_ connection: PipelineConnection) {
        switch connection {
        case let .send(source, bus): setSend(from: source, to: bus, value: nil)
        case let .route(id): routeEdit("Disconnect Output") { $0.routes.removeAll { $0.id == id } }
        }
    }
    func addOutput(_ uid: String) {
        routeEdit("Show Output") { s in
            var layout = s.pipelineLayout ?? PipelineLayout()
            if !layout.outputs.contains(uid) { layout.outputs.append(uid) }
            s.pipelineLayout = layout.sanitized
        }
    }
    func removePipelineNode(_ node: PipelineNodeID) {
        let inserts = node.kind == .strip ? session.strips.first(where: { $0.id == node.rawID })?.inserts
            : node.kind == .bus ? session.buses.first(where: { $0.id == node.rawID })?.inserts : nil
        if inserts?.contains(where: \.isPlugin) == true {
            // Take the latest native state before destroying the plugin owner,
            // so restoring a removed node does not use the last polling sample.
            capturePluginStates { self.commitNodeRemoval(node) }
        } else { commitNodeRemoval(node) }
    }
    private func commitNodeRemoval(_ node: PipelineNodeID) {
        routeEdit("Remove \(node.kind == .strip ? "Channel" : node.kind == .bus ? "Bus" : "Output")") { s in
            switch node.kind {
            case .strip: s.removeStrip(node.rawID)
            case .bus:
                guard s.buses.first(where: { $0.id == node.rawID })?.kind != "monitor" else { throw SessionError.invalid("The Monitor bus cannot be removed.") }
                s.removeBus(node.rawID)
            case .output:
                s.routes.removeAll { $0.destinationUID == node.rawID }
                if s.monitorDeviceUID == node.rawID { s.monitorDeviceUID = "" }
                s.pipelineLayout?.outputs.removeAll { $0 == node.rawID }
            }
            s.pipelineLayout?.positions.removeValue(forKey: node.key)
        }
    }
    func savePipelinePositions(_ positions: [String: PipelinePosition]) {
        var layout = session.pipelineLayout ?? PipelineLayout()
        layout.positions = positions
        session.pipelineLayout = layout.sanitized
        apply()
    }
}

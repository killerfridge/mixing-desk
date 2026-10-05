import Foundation

/// Replays only fields changed by a routing action. In particular, updating a
/// cable never restores an old fader value or a captured plugin-state snapshot.
public struct RoutingChange {
    public let name: String
    public let before: Session
    public let after: Session
    public init(_ name: String, before: Session, after: Session) { self.name = name; self.before = before; self.after = after }
    public func applying(to current: Session, backwards: Bool) throws -> Session {
        let from = backwards ? after : before, to = backwards ? before : after
        var result = current
        merge(\Session.monitorDeviceUID, from, to, &result)
        result.strips = try mergeItems(from.strips, to.strips, result.strips) { a, b, live in
            merge(\ChannelStrip.name, a, b, &live); merge(\ChannelStrip.color, a, b, &live)
            merge(\ChannelStrip.role, a, b, &live)
            merge(\SourceBinding.kind, a.source, b.source, &live.source)
            merge(\SourceBinding.deviceUID, a.source, b.source, &live.source)
            merge(\SourceBinding.bundleID, a.source, b.source, &live.source)
            merge(\SourceBinding.returnBundleID, a.source, b.source, &live.source)
            merge(\SourceBinding.channels, a.source, b.source, &live.source)
            live.sends = try mergeItems(a.sends, b.sends, live.sends, update: mergeSend)
        }
        result.buses = try mergeItems(from.buses, to.buses, result.buses) { a, b, live in
            merge(\Bus.name, a, b, &live); merge(\Bus.excludedStripID, a, b, &live)
            live.sends = try mergeItems(a.sends, b.sends, live.sends, update: mergeSend)
        }
        result.routes = try mergeItems(from.routes, to.routes, result.routes) { a, b, live in
            merge(\OutputRoute.sourceKind, a, b, &live); merge(\OutputRoute.sourceID, a, b, &live)
            merge(\OutputRoute.destinationUID, a, b, &live); merge(\OutputRoute.channels, a, b, &live)
            merge(\OutputRoute.gainDB, a, b, &live); merge(\OutputRoute.preFader, a, b, &live)
        }
        if from.pipelineLayout != to.pipelineLayout {
            let a = from.pipelineLayout ?? PipelineLayout(), b = to.pipelineLayout ?? PipelineLayout()
            var live = result.pipelineLayout ?? PipelineLayout()
            for key in Set(a.positions.keys).union(b.positions.keys) where a.positions[key] != b.positions[key] { live.positions[key] = b.positions[key] }
            let removed = Set(a.outputs).subtracting(b.outputs), added = Set(b.outputs).subtracting(a.outputs)
            live.outputs = Array(Set(live.outputs).subtracting(removed).union(added)).sorted()
            result.pipelineLayout = live
        }
        return try result.validated()
    }
}
private func merge<T, V: Equatable>(_ key: WritableKeyPath<T, V>, _ from: T, _ to: T, _ current: inout T) {
    if from[keyPath: key] != to[keyPath: key] { current[keyPath: key] = to[keyPath: key] }
}
private func mergeSend(_ a: Send, _ b: Send, _ live: inout Send) {
    merge(\Send.gainDB, a, b, &live); merge(\Send.preFader, a, b, &live)
}
private func mergeItems<T: Identifiable & Equatable>(_ from: [T], _ to: [T], _ current: [T], update: (T, T, inout T) throws -> Void) throws -> [T] where T.ID: Hashable {
    var result = current
    let old = Dictionary(uniqueKeysWithValues: from.map { ($0.id, $0) }), next = Dictionary(uniqueKeysWithValues: to.map { ($0.id, $0) })
    result.removeAll { old[$0.id] != nil && next[$0.id] == nil }
    for (index, item) in to.enumerated() {
        if let previous = old[item.id] {
            guard previous != item else { continue }
            guard let i = result.firstIndex(where: { $0.id == item.id }) else { throw SessionError.invalid("This routing edit refers to an item that has since been removed.") }
            try update(previous, item, &result[i])
        } else if !result.contains(where: { $0.id == item.id }) { result.insert(item, at: min(index, result.count)) }
    }
    return result
}
public struct RoutingHistory {
    private var past: [RoutingChange] = []
    private var future: [RoutingChange] = []
    public init() {}
    public var undoName: String? { past.last?.name }
    public var redoName: String? { future.last?.name }
    public mutating func record(_ change: RoutingChange) {
        guard change.before != change.after else { return }
        past.append(change); if past.count > 100 { past.removeFirst() }; future.removeAll()
    }
    public mutating func undo(_ current: Session) throws -> Session {
        guard let change = past.last else { return current }
        let next = try change.applying(to: current, backwards: true)
        past.removeLast(); future.append(RoutingChange(change.name, before: next, after: current))
        return next
    }
    public mutating func redo(_ current: Session) throws -> Session {
        guard let change = future.last else { return current }
        let next = try change.applying(to: current, backwards: false)
        future.removeLast(); past.append(RoutingChange(change.name, before: current, after: next))
        return next
    }
    public mutating func clear() { past.removeAll(); future.removeAll() }
}

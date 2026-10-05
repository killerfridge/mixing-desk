import Foundation

/// Presentation only: never sent to the audio controller.
public struct PipelinePosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var usable: Bool { x.isFinite && y.isFinite && (0..<1_000_000).contains(x) && (0..<1_000_000).contains(y) }
}
public struct PipelineLayout: Codable, Equatable, Sendable {
    public var positions: [String: PipelinePosition] = [:]
    public var outputs: [String] = []
    public init() {}
    public var sanitized: PipelineLayout {
        var result = self
        result.positions = positions.filter { !$0.key.isEmpty && $0.value.usable }
        result.outputs = Array(Set(outputs.filter { !$0.isEmpty })).sorted()
        return result
    }
}
public enum PipelineKind: String, Codable, Sendable { case strip, bus, output }
public struct PipelineNodeID: Hashable, Sendable {
    public let kind: PipelineKind
    public let rawID: String
    public var key: String { "\(kind.rawValue):\(rawID)" }
    public init(_ kind: PipelineKind, _ rawID: String) { self.kind = kind; self.rawID = rawID }
}
public enum PipelineConnection: Hashable, Sendable {
    case send(PipelineNodeID, String)
    case route(String)
}
public struct PipelineEdge: Identifiable, Equatable, Sendable {
    public let id: PipelineConnection
    public let source: PipelineNodeID
    public let destination: PipelineNodeID
    public let gainDB: Double
    public let preFader: Bool
    public let channels: [Int]
    public var off: Bool { gainDB <= -90 }
}
public struct PipelineTrace {
    public var reached: Set<PipelineConnection> = []
    public var excluded: Set<PipelineConnection> = []
    public init() {}
}
/// A projection, not a second routing model. All IDs refer to the session.
public struct PipelineGraph {
    public let nodes: [PipelineNodeID]
    public let edges: [PipelineEdge]
    public init(_ session: Session) {
        var seenOutputs: Set<String> = []
        let outputs = ([session.monitorDeviceUID] + session.routes.map(\.destinationUID) + (session.pipelineLayout?.outputs ?? [])).filter { !$0.isEmpty && seenOutputs.insert($0).inserted }
        nodes = session.strips.map { PipelineNodeID(.strip, $0.id) } + session.buses.map { PipelineNodeID(.bus, $0.id) } + outputs.map { PipelineNodeID(.output, $0) }
        var result: [PipelineEdge] = []
        func append(_ source: PipelineNodeID, _ sends: [Send]) {
            for send in sends { result.append(PipelineEdge(id: .send(source, send.busID), source: source, destination: PipelineNodeID(.bus, send.busID), gainDB: send.gainDB, preFader: source.kind == .strip && send.preFader, channels: [])) }
        }
        for strip in session.strips { append(PipelineNodeID(.strip, strip.id), strip.sends) }
        for bus in session.buses { append(PipelineNodeID(.bus, bus.id), bus.sends) }
        for route in session.routes { result.append(PipelineEdge(id: .route(route.id), source: PipelineNodeID(route.sourceKind == "strip" ? .strip : .bus, route.sourceID), destination: PipelineNodeID(.output, route.destinationUID), gainDB: route.gainDB, preFader: route.sourceKind == "strip" && route.preFader, channels: route.channels)) }
        edges = result
    }
    /// Stable topological columns; device discovery order never enters layout.
    public func arranged() -> [String: PipelinePosition] {
        var ranks = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0.kind == .strip ? 0 : 1) })
        // Session validation guarantees a DAG. Bound iterations for defensive use.
        for _ in 0..<nodes.count {
            var changed = false
            for edge in edges where edge.destination.kind == .bus && edge.source.kind == .bus {
                let next = (ranks[edge.source] ?? 0) + 1
                if next > (ranks[edge.destination] ?? 0) { ranks[edge.destination] = next; changed = true }
            }
            if !changed { break }
        }
        let outputRank = (nodes.filter { $0.kind == .bus }.map { ranks[$0] ?? 1 }.max() ?? 1) + 1
        var rows: [Int: Int] = [:], result: [String: PipelinePosition] = [:]
        for node in nodes {
            let column = node.kind == .output ? outputRank : ranks[node] ?? 0
            let row = rows[column, default: 0]; rows[column] = row + 1
            result[node.key] = PipelinePosition(x: 50 + Double(column) * 350, y: 55 + Double(row) * 250)
        }
        return result
    }
    public static func excludes(_ bus: Bus, source: SourceBinding, in session: Session) -> Bool {
        guard let excluded = session.strips.first(where: { $0.id == bus.excludedStripID }) else { return false }
        return excluded.source.key == source.key
    }
    public func directlyExcluded(_ edge: PipelineEdge, in session: Session) -> Bool {
        guard edge.source.kind == .strip, edge.destination.kind == .bus,
              let strip = session.strips.first(where: { $0.id == edge.source.rawID }),
              let bus = session.buses.first(where: { $0.id == edge.destination.rawID }) else { return false }
        return Self.excludes(bus, source: strip.source, in: session)
    }
    public func trace(from start: PipelineNodeID, in session: Session) -> PipelineTrace {
        let strip = session.strips.first { start.kind == .strip && $0.id == start.rawID }
        let outgoing = Dictionary(grouping: edges, by: \.source)
        var result = PipelineTrace(), visited: Set<PipelineNodeID> = []
        func visit(_ node: PipelineNodeID) {
            guard visited.insert(node).inserted else { return }
            for edge in outgoing[node] ?? [] {
                result.reached.insert(edge.id)
                var blocked = false
                if let strip {
                    if let bus = session.buses.first(where: { edge.destination.kind == .bus && $0.id == edge.destination.rawID }) { blocked = Self.excludes(bus, source: strip.source, in: session) }
                    if edge.destination.kind == .output, let bus = session.buses.first(where: { node.kind == .bus && $0.id == node.rawID }), bus.kind == "monitor" {
                        blocked = (session.strips.contains(where: \.solo) && !strip.solo) || (session.monitoringMode == "directGuitar" && strip.role == "guitar")
                    }
                }
                if blocked { result.excluded.insert(edge.id) }
                else if !edge.off { visit(edge.destination) }
            }
        }
        visit(start)
        return result
    }
}

public extension Session {
    var audioSession: Session { var result = self; result.pipelineLayout = nil; return result }
    func sends(from source: PipelineNodeID) -> [Send] {
        source.kind == .strip ? strips.first(where: { $0.id == source.rawID })?.sends ?? [] : buses.first(where: { $0.id == source.rawID })?.sends ?? []
    }
    mutating func setSend(from source: PipelineNodeID, to busID: String, value: Send?) throws {
        guard source.kind != .output, buses.contains(where: { $0.id == busID }) else { throw SessionError.invalid("Choose a channel or bus feeding an existing bus.") }
        func replace(_ sends: inout [Send]) {
            if let i = sends.firstIndex(where: { $0.busID == busID }) {
                if let value { sends[i] = value } else { sends.remove(at: i) }
            } else if let value { sends.append(value) }
        }
        if source.kind == .strip, let i = strips.firstIndex(where: { $0.id == source.rawID }) { replace(&strips[i].sends) }
        else if source.kind == .bus, let i = buses.firstIndex(where: { $0.id == source.rawID }) { replace(&buses[i].sends) }
        else { throw SessionError.invalid("The source no longer exists.") }
    }
}

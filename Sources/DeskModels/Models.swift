import Foundation

public struct SourceBinding: Codable, Equatable, Sendable {
    public var kind = "device"
    public var deviceUID = ""
    public var bundleID = ""
    public var returnBundleID = ""
    public var channels = [0]
    public init() {}
    public var key: String { kind == "application" ? "app:\(bundleID)" : returnBundleID.isEmpty ? "device:\(deviceUID)" : "app:\(returnBundleID)" }
}
public struct InsertSlot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var format: String
    public var identifier: String
    public var bypassed: Bool
    public var state: Data?
    public var name: String?
    public init(format: String, identifier: String, bypassed: Bool = false, state: Data? = nil) {
        self.format = format; self.identifier = identifier; self.bypassed = bypassed; self.state = state
    }
    public static func equalizer() -> InsertSlot { InsertSlot(format: "builtin", identifier: "local.mixingdesk.eq") }
    public static func audioUnit(identifier: String, name: String) -> InsertSlot {
        var slot = InsertSlot(format: "au", identifier: identifier); slot.name = name; return slot
    }
    public static func vst3(identifier: String, name: String) -> InsertSlot {
        var slot = InsertSlot(format: "vst3", identifier: identifier); slot.name = name; return slot
    }
    public var isPlugin: Bool { format == "au" || format == "vst3" }
    public var formatName: String { format == "vst3" ? "VST3" : format == "au" ? "AUv2" : "Built-in" }
    public var displayName: String { format == "builtin" ? "Desk EQ" : name ?? formatName }

    public func validated() throws {
        if format == "builtin" { _ = try decodedEQ(); return }
        if format == "vst3" {
            guard identifier.range(of: "^[0-9A-F]{32}$", options: .regularExpression) != nil else { throw SessionError.invalid("Invalid VST3 class identifier.") }
            if let state {
                guard state.count <= 16 * 1024 * 1024,
                      let value = try? PropertyListSerialization.propertyList(from: state, format: nil) as? [String: Any],
                      value["version"] as? Int == 1, value["classID"] as? String == identifier,
                      value["component"] is Data,
                      value["controller"] == nil || value["controller"] is Data,
                      let parameters = value["parameters"] as? [[String: Any]], parameters.count <= 32768,
                      parameters.allSatisfy({ item in
                          guard let id = item["id"] as? NSNumber, let number = item["value"] as? NSNumber else { return false }
                          return id.doubleValue >= 0 && id.doubleValue <= Double(UInt32.max) && id.doubleValue.rounded() == id.doubleValue && number.doubleValue.isFinite && (0...1).contains(number.doubleValue)
                      })
                else { throw SessionError.invalid("Invalid VST3 state (maximum 16 MB).") }
            }
            return
        }
        guard format == "au", identifier.range(of: "^(61756678|61756d66):[0-9a-f]{8}:[0-9a-f]{8}$", options: .regularExpression) != nil else { throw SessionError.invalid("Unsupported insert: \(identifier).") }
        if let state {
            guard state.count <= 16 * 1024 * 1024,
                  (try? PropertyListSerialization.propertyList(from: state, format: nil)) is [String: Any]
            else { throw SessionError.invalid("Invalid Audio Unit state (maximum 16 MB).") }
        }
    }
    public func decodedEQ() throws -> EQSettings {
        guard format == "builtin", identifier == "local.mixingdesk.eq" else { throw SessionError.invalid("Unsupported insert: \(identifier).") }
        let settings = try state.map { try JSONDecoder().decode(EQSettings.self, from: $0) } ?? EQSettings()
        return try settings.validated()
    }
    public var eq: EQSettings {
        get { (try? decodedEQ()) ?? EQSettings() }
        set { state = try? JSONEncoder().encode(newValue) }
    }
}
public struct EQSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var lowFrequency: Double = 120
    public var lowGain: Double = 0
    public var midFrequency: Double = 1000
    public var midGain: Double = 0
    public var midQ: Double = 1
    public var highFrequency: Double = 8000
    public var highGain: Double = 0
    public var outputGain: Double = 0
    public init() {}
    public func validated() throws -> EQSettings {
        let frequencies = [lowFrequency, midFrequency, highFrequency]
        let gains = [lowGain, midGain, highGain, outputGain]
        guard version == 1, frequencies.allSatisfy({ $0.isFinite && (20...20000).contains($0) }),
              gains.allSatisfy({ $0.isFinite && (-18...18).contains($0) }), midQ.isFinite, (0.1...10).contains(midQ)
        else { throw SessionError.invalid("Invalid EQ settings or unsupported EQ state version.") }
        return self
    }
}
public struct Send: Codable, Equatable, Identifiable, Sendable {
    public var id: String { busID }
    public var busID: String
    public var gainDB: Double = 0
    public var preFader = false
    public init(busID: String, gainDB: Double = 0, preFader: Bool = false) { self.busID = busID; self.gainDB = gainDB; self.preFader = preFader }
}
public struct ChannelStrip: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name = "Channel"
    public var color = "teal"
    public var role = "generic"
    public var source = SourceBinding()
    public var trimDB: Double = 0
    public var faderDB: Double = 0
    public var pan: Double = 0
    public var polarity = false
    public var muted = false
    public var solo = false
    public var sends: [Send] = []
    public var inserts: [InsertSlot] = []
    public init(name: String = "Channel") { self.name = name }
}
public struct Bus: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var name: String
    public var kind: String
    public var gainDB: Double = 0
    public var muted = false
    public var excludedStripID = ""
    public var sends: [Send] = []
    public var inserts: [InsertSlot] = []
    public init(name: String, kind: String = "mix") { self.name = name; self.kind = kind }
}
public struct OutputRoute: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var sourceKind = "bus"
    public var sourceID: String
    public var preFader = false
    public var destinationUID: String
    public var channels = [0, 1]
    public var gainDB: Double = 0
    public init(sourceKind: String = "bus", sourceID: String, destinationUID: String, channels: [Int] = [0, 1]) {
        self.sourceKind = sourceKind; self.sourceID = sourceID; self.destinationUID = destinationUID; self.channels = channels
    }
}
public struct Session: Codable, Equatable, Sendable {
    public var version = 1
    public var name = "My Desk"
    public var monitorDeviceUID = ""
    public var bufferFrames = 128
    public var monitoringMode = "mixer"
    public var strips: [ChannelStrip] = []
    public var buses: [Bus] = []
    public var routes: [OutputRoute] = []
    public init() {}
    public static func starter() -> Session {
        var session = Session()
        session.buses = [Bus(name: "Monitor", kind: "monitor"), Bus(name: "Call", kind: "call"), Bus(name: "Stream")]
        var mic = ChannelStrip(name: "Microphone"); mic.color = "teal"
        var guitar = ChannelStrip(name: "Guitar"); guitar.role = "guitar"; guitar.color = "amber"; guitar.source.channels = [0, 1]
        var music = ChannelStrip(name: "Application"); music.color = "purple"; music.source.kind = "application"; music.source.channels = [0, 1]
        var caller = ChannelStrip(name: "Call Return"); caller.color = "blue"; caller.role = "callReturn"; caller.source.kind = "application"; caller.source.bundleID = "us.zoom.xos"; caller.source.channels = [0, 1]
        for strip in [mic, guitar, music, caller] {
            var s = strip; s.sends = session.buses.map { Send(busID: $0.id) }; session.strips.append(s)
        }
        session.buses[1].excludedStripID = caller.id
        return session
    }
    public func validated() throws -> Session {
        func require(_ ok: Bool, _ message: String) throws { if !ok { throw SessionError.invalid(message) } }
        try require(version == 1, "Unsupported session version \(version).")
        try require(strips.count <= 64 && buses.count <= 16 && routes.count <= 512, "Capacity: 64 strips, 16 buses, 512 output routes.")
        try require([32, 64, 128, 256, 512, 1024, 2048, 4096].contains(bufferFrames), "Invalid buffer size.")
        try require(["mixer", "directGuitar"].contains(monitoringMode), "Invalid monitoring mode.")
        var ids = strips.map(\.id) + buses.map(\.id) + routes.map(\.id)
        ids += strips.flatMap { $0.inserts.map(\.id) }
        ids += buses.flatMap { $0.inserts.map(\.id) }
        try require(Set(ids).count == ids.count && !ids.contains(""), "Session identifiers must be unique.")
        try require(buses.filter { $0.kind == "monitor" }.count == 1, "Exactly one Monitor bus is required.")
        let busIDs = Set(buses.map(\.id)), stripIDs = Set(strips.map(\.id))
        func gain(_ value: Double) -> Bool { value.isFinite && (-90...24).contains(value) }
        func checkSends(_ sends: [Send]) throws {
            try require(sends.count <= 16 && Set(sends.map(\.busID)).count == sends.count, "Duplicate or excessive sends.")
            for send in sends { try require(busIDs.contains(send.busID) && gain(send.gainDB), "Invalid send destination or gain.") }
        }
        func checkInserts(_ inserts: [InsertSlot]) throws {
            try require(inserts.count <= 4, "Up to four inserts are supported per channel or bus.")
            for insert in inserts { try insert.validated() }
        }
        var taps = Set<String>(), returns = Set<String>()
        for strip in strips {
            try require(gain(strip.trimDB) && gain(strip.faderDB) && strip.pan.isFinite && (-1...1).contains(strip.pan), "Invalid channel gain or pan.")
            try require(["device", "application"].contains(strip.source.kind), "Invalid source type.")
            try require((1...2).contains(strip.source.channels.count) && strip.source.channels.allSatisfy { (0..<512).contains($0) } && Set(strip.source.channels).count == strip.source.channels.count, "Choose one input channel or two different stereo channels.")
            if strip.source.kind == "application" && !strip.source.bundleID.isEmpty { taps.insert(strip.source.bundleID) }
            if !strip.source.returnBundleID.isEmpty { returns.insert(strip.source.returnBundleID) }
            try checkSends(strip.sends)
            try checkInserts(strip.inserts)
        }
        try require(taps.isDisjoint(with: returns), "An application cannot use both a tap and a virtual return.")
        for bus in buses {
            try require(gain(bus.gainDB) && ["monitor", "call", "mix"].contains(bus.kind), "Invalid bus gain or type.")
            try require(bus.excludedStripID.isEmpty || stripIDs.contains(bus.excludedStripID), "The excluded return source is missing.")
            try checkSends(bus.sends)
            try checkInserts(bus.inserts)
            try require(!bus.inserts.contains(where: { $0.isPlugin }) || bus.sends.isEmpty,
                        "Plugins need an output bus with no sends to other buses. Remove that bus's sends, or put the plugin on a channel.")
        }
        var visiting = Set<String>(), visited = Set<String>()
        let graph = Dictionary(uniqueKeysWithValues: buses.map { ($0.id, $0.sends.map(\.busID)) })
        func visit(_ id: String) throws {
            if visited.contains(id) { return }
            try require(!visiting.contains(id), "This patch would create a feedback cycle.")
            visiting.insert(id)
            for child in graph[id] ?? [] { try visit(child) }
            visiting.remove(id); visited.insert(id)
        }
        for bus in buses { try visit(bus.id) }
        for route in routes {
            try require(["bus", "strip"].contains(route.sourceKind), "Invalid route type.")
            try require((route.sourceKind == "bus" ? busIDs : stripIDs).contains(route.sourceID), "Route source is missing.")
            try require(gain(route.gainDB) && (1...2).contains(route.channels.count) && route.channels.allSatisfy { (0..<512).contains($0) } && Set(route.channels).count == route.channels.count, "Invalid output route channels or level.")
        }
        return self
    }
    public func data() throws -> Data { _ = try validated(); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return try encoder.encode(self) }
    public static func decode(_ data: Data) throws -> Session { try JSONDecoder().decode(Session.self, from: data).validated() }
    public func dictionary() throws -> [String: Any] { try JSONSerialization.jsonObject(with: data()) as! [String: Any] }
    public mutating func removeStrip(_ id: String) {
        strips.removeAll { $0.id == id }; routes.removeAll { $0.sourceKind == "strip" && $0.sourceID == id }
        for i in buses.indices where buses[i].excludedStripID == id { buses[i].excludedStripID = "" }
    }
    public mutating func removeBus(_ id: String) {
        guard buses.first(where: { $0.id == id })?.kind != "monitor" else { return }
        buses.removeAll { $0.id == id }; routes.removeAll { $0.sourceKind == "bus" && $0.sourceID == id }
        for i in strips.indices { strips[i].sends.removeAll { $0.busID == id } }
        for i in buses.indices { buses[i].sends.removeAll { $0.busID == id } }
    }
}
public enum SessionError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

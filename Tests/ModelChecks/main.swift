import Foundation
import DeskModels

func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { fatalError(message) }
}
func rejects(_ session: Session) { do { _ = try session.validated(); fatalError("Expected rejection") } catch {} }

let original = Session.starter()
try expect(original.strips.count == 3 && original.monitorDeviceUID.isEmpty && original.routes.isEmpty, "New desks have no hardware routes")
try expect(original.strips.allSatisfy { $0.source.deviceUID.isEmpty && $0.source.bundleID.isEmpty }, "New desks have no personal device or application bindings")
try expect(Session.decode(original.data()) == original, "Session round trip")
try expect(original.buses[1].excludedStripID == original.strips[2].id, "Default mix-minus")
var session = original
session.buses[0].sends = [Send(busID: session.buses[1].id)]
session.buses[1].sends = [Send(busID: session.buses[2].id)]
session.buses[2].sends = [Send(busID: session.buses[0].id)]
rejects(session)
session = original; session.strips[2].source.bundleID = "us.zoom.xos"; session.strips[0].source.returnBundleID = "us.zoom.xos"; rejects(session)
session = original; session.version = 2; rejects(session)
session = original; session.strips[0].faderDB = .nan; rejects(session)
session = original; session.strips[0].source.deviceUID = "unplugged-rode"
try expect(Session.decode(session.data()).strips[0].source.deviceUID == "unplugged-rode", "Offline binding persistence")
session = original; let caller = session.strips[2].id
session.routes = [OutputRoute(sourceKind: "strip", sourceID: caller, destinationUID: "offline")]
session.removeStrip(caller)
try expect(session.routes.isEmpty && session.buses[1].excludedStripID.isEmpty, "Remove source references")
_ = try session.validated()
session = original; let call = session.buses[1].id; session.removeBus(call); session.removeBus(session.buses[0].id)
try expect(session.buses.count == 2 && session.strips.allSatisfy { !$0.sends.contains { $0.busID == call } }, "Bus cleanup and monitor preservation")
_ = try session.validated()
session = original; session.strips[0].source.channels = [0,0]; rejects(session)
session = original; session.strips[1].id = session.strips[0].id; rejects(session)
session = original; var route = OutputRoute(sourceKind: "strip", sourceID: session.strips[0].id, destinationUID: "recording", channels: [7]); route.preFader = true; session.routes = [route]
try expect(Session.decode(session.data()).routes[0] == route, "Direct recording route persistence")
print("PASS: session round trips, default mix-minus, feedback-cycle rejection, duplicate-capture rejection, schema/gain/channel validation, offline bindings, removal cleanup and direct recording persistence.")

// EQ slots are typed/versioned state, while existing v1 desks without inserts still load.
session = original
var eq = InsertSlot.equalizer(); var settings = eq.eq
settings.lowGain = 6; settings.midFrequency = 2200; settings.midQ = 2.4
settings.outputGain = -3; eq.eq = settings; eq.bypassed = true
session.strips[0].inserts = [eq]; session.buses[2].inserts = [.equalizer()]
try expect(Session.decode(session.data()) == session, "EQ state/order/bypass round trip")
try expect(session.strips[0].inserts[0].decodedEQ() == settings, "EQ settings decode")
session.strips[0].inserts[0].state = Data("bad JSON".utf8); rejects(session)
session = original; eq = .equalizer(); settings = eq.eq; settings.midQ = 0; eq.eq = settings
session.strips[0].inserts = [eq]; rejects(session)
settings = EQSettings(); settings.version = 99; eq.eq = settings
session.strips[0].inserts = [eq]; rejects(session)
session = original; session.strips[0].inserts = [InsertSlot(format: "au", identifier: "unknown", bypassed: true)]; rejects(session)
session = original; session.strips[0].inserts = (0..<5).map { _ in .equalizer() }; rejects(session)
session = original; eq = .equalizer(); session.strips[0].inserts = [eq]; session.buses[0].inserts = [eq]; rejects(session)
print("PASS: EQ JSON state and bypass persistence; malformed, out-of-range, unknown-version, unsupported, excessive and duplicate insert rejection.")

// Audio Unit identities and opaque property-list states persist even offline.
session = original
var au = InsertSlot.audioUnit(identifier: "61756678:68706173:6170706c", name: "AUHipass")
au.state = try PropertyListSerialization.data(fromPropertyList: ["version": 0, "type": 0x61756678, "subtype": 0x68706173, "manufacturer": 0x6170706c], format: .binary, options: 0)
session.strips[0].inserts = [au]
try expect(Session.decode(session.data()) == session, "Audio Unit identity/name/state persistence")
session.strips[0].inserts[0].state = Data("not a property list".utf8); rejects(session)
session = original; session.buses[1].inserts = [au]
_ = try session.validated()
session.buses[1].sends = [Send(busID: session.buses[2].id)]; rejects(session)
print("PASS: Audio Unit state and offline identity persistence, malformed state and unsafe downstream bus-route rejection.")

// VST3 uses a portable class ID; processor, controller and pending UI values
// are captured together. Mixed-format sessions keep their order and identities.
session = original
var vst = InsertSlot.vst3(identifier: "00112233445566778899AABBCCDDEEFF", name: "Test Gain")
vst.state = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "classID": vst.identifier, "component": Data([1, 2, 3]), "controller": Data([4]), "parameters": [["id": 42, "value": 0.25]]], format: .binary, options: 0)
vst.bypassed = true
session.strips[0].inserts = [.equalizer(), au, vst]
try expect(Session.decode(session.data()) == session, "Mixed EQ/AUv2/VST3 state/order/bypass round trip")
session.buses[2].inserts = [.vst3(identifier: vst.identifier, name: "Missing Effect")]
_ = try session.validated()
session.buses[2].sends = [Send(busID: session.buses[0].id)]; rejects(session)
session = original; session.strips[0].inserts = [vst]
session.strips[0].inserts[0].identifier = "../effect.vst3"; rejects(session)
session.strips[0].inserts = [vst]; session.strips[0].inserts[0].state = Data("invalid".utf8); rejects(session)
for value in [Double.nan, -0.1, 1.1] {
    var invalid = vst
    invalid.state = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "classID": vst.identifier, "component": Data(), "parameters": [["id": 42, "value": value]]], format: .binary, options: 0)
    session.strips[0].inserts = [invalid]; rejects(session)
}
for id in ["FFEEDDCCBBAA99887766554433221100", vst.identifier.lowercased()] {
    var invalid = vst; invalid.identifier = id; session.strips[0].inserts = [invalid]; rejects(session)
}
print("PASS: mixed EQ/AUv2/VST3 persistence, missing VST3 identity, class/state/parameter validation and VST3 bus routing restrictions.")

try pipelineModelChecks()

import XCTest
import DeskModels

final class SessionTests: XCTestCase {
    func testStarterSessionRoundTrip() throws {
        let session = Session.starter()
        XCTAssertEqual(session.strips.count, 3)
        XCTAssertTrue(session.monitorDeviceUID.isEmpty && session.routes.isEmpty)
        XCTAssertTrue(session.strips.allSatisfy { $0.source.deviceUID.isEmpty && $0.source.bundleID.isEmpty })
        XCTAssertEqual(try Session.decode(session.data()), session)
        XCTAssertEqual(session.buses.first { $0.kind == "call" }?.excludedStripID, session.strips.first { $0.role == "callReturn" }?.id)
    }
    func testExistingSessionProtectionDefaultsAndBypassPersistence() throws {
        var session = Session.starter()
        var legacy = try JSONSerialization.jsonObject(with: session.data()) as! [String: Any]
        legacy.removeValue(forKey: "outputProtectionEnabled")
        var strips = legacy["strips"] as! [[String: Any]]
        for i in strips.indices { strips[i].removeValue(forKey: "limiterEnabled") }
        legacy["strips"] = strips
        let old = try Session.decode(JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(old.version, 1); XCTAssertTrue(old.outputProtectionEnabled)
        XCTAssertTrue(old.strips.allSatisfy(\.limiterEnabled))
        session.outputProtectionEnabled = false; session.strips[0].limiterEnabled = false
        XCTAssertEqual(try Session.decode(session.data()), session)
    }
    func testRejectsRoutingCycles() throws {
        var session = Session.starter()
        session.buses[0].sends = [Send(busID: session.buses[1].id)]
        session.buses[1].sends = [Send(busID: session.buses[2].id)]
        session.buses[2].sends = [Send(busID: session.buses[0].id)]
        XCTAssertThrowsError(try session.validated())
    }
    func testRejectsDuplicateCapture() {
        var session = Session.starter()
        session.strips[2].source.bundleID = "us.zoom.xos"; session.strips[0].source.returnBundleID = "us.zoom.xos"
        XCTAssertThrowsError(try session.validated())
    }
    func testRejectsUnknownVersionAndInvalidNumbers() {
        var session = Session.starter(); session.version = 2
        XCTAssertThrowsError(try session.validated())
        session.version = 1; session.strips[0].faderDB = .nan
        XCTAssertThrowsError(try session.validated())
    }
    func testOfflineBindingsPersist() throws {
        var session = Session.starter(); session.strips[0].source.deviceUID = "unplugged-rode"
        XCTAssertEqual(try Session.decode(session.data()).strips[0].source.deviceUID, "unplugged-rode")
    }
    func testRemovingSourceCleansReferences() throws {
        var session = Session.starter(); let caller = session.strips[2].id
        session.routes.append(OutputRoute(sourceKind: "strip", sourceID: caller, destinationUID: "offline"))
        session.removeStrip(caller)
        XCTAssertTrue(session.routes.isEmpty)
        XCTAssertTrue(session.buses[1].excludedStripID.isEmpty)
        _ = try session.validated()
    }
    func testRemovingBusCleansReferencesAndPreservesMonitor() throws {
        var session = Session.starter(); let call = session.buses[1].id, monitor = session.buses[0].id
        session.removeBus(call); session.removeBus(monitor)
        XCTAssertEqual(session.buses.count, 2)
        XCTAssertTrue(session.strips.allSatisfy { !$0.sends.contains { $0.busID == call } })
        _ = try session.validated()
    }
    func testRejectsDuplicateStereoChannelsAndIDs() {
        var session = Session.starter(); session.strips[0].source.channels = [0,0]
        XCTAssertThrowsError(try session.validated())
        session = .starter(); session.strips[1].id = session.strips[0].id
        XCTAssertThrowsError(try session.validated())
    }
    func testDirectRecordingRouteRoundTrip() throws {
        var session = Session.starter(); var route = OutputRoute(sourceKind: "strip", sourceID: session.strips[0].id, destinationUID: "recording", channels: [7]); route.preFader = true
        session.routes = [route]
        XCTAssertEqual(try Session.decode(session.data()).routes[0], route)
    }
    func testEqualizerStateOrderAndBypassRoundTrip() throws {
        var session = Session.starter(), insert = InsertSlot.equalizer()
        var settings = insert.eq
        settings.lowGain = 6; settings.midFrequency = 2200; settings.midQ = 2.4
        settings.outputGain = -3; insert.eq = settings; insert.bypassed = true
        session.strips[0].inserts = [insert, .equalizer()]
        session.buses[2].inserts = [.equalizer()]
        let restored = try Session.decode(session.data())
        XCTAssertEqual(restored, session)
        XCTAssertEqual(try restored.strips[0].inserts[0].decodedEQ(), settings)
    }
    func testRejectsInvalidEqualizersAndUnsupportedInserts() {
        var session = Session.starter(), insert = InsertSlot.equalizer()
        insert.state = Data("bad JSON".utf8)
        session.strips[0].inserts = [insert]
        XCTAssertThrowsError(try session.validated())
        var settings = EQSettings(); settings.midQ = 0; insert.eq = settings
        session.strips[0].inserts = [insert]
        XCTAssertThrowsError(try session.validated())
        settings = EQSettings(); settings.version = 99; insert.eq = settings
        session.strips[0].inserts = [insert]
        XCTAssertThrowsError(try session.validated())
        session.strips[0].inserts = [InsertSlot(format: "au", identifier: "unknown", bypassed: true)]
        XCTAssertThrowsError(try session.validated())
        session.strips[0].inserts = (0..<5).map { _ in .equalizer() }
        XCTAssertThrowsError(try session.validated())
        insert = .equalizer(); session.strips[0].inserts = [insert]; session.buses[0].inserts = [insert]
        XCTAssertThrowsError(try session.validated())
    }
    func testAudioUnitStateAndOfflineIdentityRoundTrip() throws {
        var session = Session.starter()
        var unit = InsertSlot.audioUnit(identifier: "61756678:68706173:6170706c", name: "AUHipass")
        unit.state = try PropertyListSerialization.data(fromPropertyList: ["version": 0, "type": 0x61756678, "subtype": 0x68706173, "manufacturer": 0x6170706c], format: .binary, options: 0)
        session.strips[0].inserts = [unit]
        XCTAssertEqual(try Session.decode(session.data()), session)
        session.strips[0].inserts[0].state = Data("bad preset".utf8)
        XCTAssertThrowsError(try session.validated())
    }
    func testAudioUnitBusesCannotFeedDownstreamMixMinus() throws {
        var session = Session.starter()
        session.buses[1].inserts = [.audioUnit(identifier: "61756678:68706173:6170706c", name: "AUHipass")]
        XCTAssertNoThrow(try session.validated())
        session.buses[1].sends = [Send(busID: session.buses[2].id)]
        XCTAssertThrowsError(try session.validated())
    }
    func testMixedPluginStateRoundTrip() throws {
        var session = Session.starter()
        var vst = InsertSlot.vst3(identifier: "00112233445566778899AABBCCDDEEFF", name: "Test Gain")
        vst.bypassed = true
        vst.state = try PropertyListSerialization.data(fromPropertyList: ["version": 1, "classID": vst.identifier, "component": Data([1, 2]), "parameters": [["id": 42, "value": 0.25]]], format: .binary, options: 0)
        session.strips[0].inserts = [.equalizer(), .audioUnit(identifier: "61756678:68706173:6170706c", name: "AUHipass"), vst]
        XCTAssertEqual(try Session.decode(session.data()), session)
        session.strips[0].inserts[2].identifier = "FFEEDDCCBBAA99887766554433221100"
        XCTAssertThrowsError(try session.validated())
        session.strips[0].inserts[2] = vst
        session.strips[0].inserts[2].state = Data("invalid state".utf8)
        XCTAssertThrowsError(try session.validated())
    }
    func testVST3BusCannotFeedDownstreamMixMinus() throws {
        var session = Session.starter()
        session.buses[1].inserts = [.vst3(identifier: "00112233445566778899AABBCCDDEEFF", name: "Missing Effect")]
        XCTAssertNoThrow(try session.validated())
        session.buses[1].sends = [Send(busID: session.buses[2].id)]
        XCTAssertThrowsError(try session.validated())
        session.buses[1].sends = []
        session.buses[1].inserts[0].identifier = "../../effect.vst3"
        XCTAssertThrowsError(try session.validated())
    }

}

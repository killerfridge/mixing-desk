import XCTest
import DeskModels

final class PipelineTests: XCTestCase {
    func testLayoutIsOptionalAndExcludedFromAudioPayload() throws {
        var session = Session.starter()
        XCTAssertNil(try Session.decode(session.data()).pipelineLayout)
        var layout = PipelineLayout()
        layout.positions[PipelineNodeID(.strip, session.strips[0].id).key] = PipelinePosition(x: 10, y: 20)
        layout.outputs = ["offline"]
        session.pipelineLayout = layout
        XCTAssertEqual(try Session.decode(session.data()), session)
        XCTAssertNil(try session.dictionary()["pipelineLayout"])
        var json = try JSONSerialization.jsonObject(with: session.data()) as! [String: Any]
        json["pipelineLayout"] = "unsupported presentation"
        XCTAssertEqual(try Session.decode(JSONSerialization.data(withJSONObject: json)).audioSession, session.audioSession)
    }
    func testRoutingUndoPreservesLiveMixAndPlugins() throws {
        var before = Session.starter()
        before.strips[0].inserts = [.equalizer()]
        var after = before
        after.strips[0].sends[0].gainDB = -12
        var history = RoutingHistory()
        history.record(RoutingChange("Send", before: before, after: after))
        after.strips[0].faderDB = -7
        after.strips[0].inserts[0].eq.lowGain = 5
        let undone = try history.undo(after)
        XCTAssertEqual(undone.strips[0].sends, before.strips[0].sends)
        XCTAssertEqual(undone.strips[0].faderDB, -7)
        XCTAssertEqual(undone.strips[0].inserts[0].eq.lowGain, 5)
        XCTAssertEqual(try history.redo(undone), after)
    }
    func testExclusionUsesSourceIdentityAcrossBusPaths() throws {
        var session = Session.starter()
        session.strips[2].source.bundleID = "call"
        session.strips[0].source = session.strips[2].source
        session.buses[0].sends = [Send(busID: session.buses[1].id)]
        let graph = PipelineGraph(session), source = PipelineNodeID(.strip, session.strips[0].id)
        let trace = graph.trace(from: source, in: session)
        XCTAssertTrue(trace.excluded.contains(.send(source, session.buses[1].id)))
        XCTAssertTrue(trace.excluded.contains(.send(PipelineNodeID(.bus, session.buses[0].id), session.buses[1].id)))
    }
    func testOfflineOutputAndBusOrderRemainInGraph() {
        var session = Session.starter()
        session.buses[2].sends = [Send(busID: session.buses[1].id)]
        session.routes = [OutputRoute(sourceID: session.buses[1].id, destinationUID: "offline")]
        let graph = PipelineGraph(session), positions = graph.arranged()
        XCTAssertTrue(graph.nodes.contains(PipelineNodeID(.output, "offline")))
        XCTAssertLessThan(positions[PipelineNodeID(.bus, session.buses[2].id).key]!.x, positions[PipelineNodeID(.bus, session.buses[1].id).key]!.x)
    }
}

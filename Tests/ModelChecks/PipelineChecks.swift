import Foundation
import DeskModels

func pipelineModelChecks() throws {
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { fatalError("Pipeline: \(message)") }
    }
    var original = Session.starter()
    original.strips[0].source.deviceUID = "interface"
    original.strips[2].source.bundleID = "example.call"
    original.strips[0].inserts = [.equalizer()]
    let source = PipelineNodeID(.strip, original.strips[0].id)
    let bus = original.buses[0].id
    var connected = original
    try connected.setSend(from: source, to: bus, value: Send(busID: bus, gainDB: -6, preFader: true))
    var history = RoutingHistory()
    history.record(RoutingChange("Send", before: original, after: connected))
    connected.strips[0].faderDB = -19
    connected.strips[0].inserts[0].eq.midGain = 8
    let undone = try history.undo(connected)
    try check(undone.strips[0].sends == original.strips[0].sends, "undo restores send")
    try check(undone.strips[0].faderDB == -19 && undone.strips[0].inserts[0].eq.midGain == 8, "undo preserves unrelated fader and effect state")
    try check(history.redo(undone) == connected, "redo round trip")
    var removed = connected; removed.removeStrip(source.rawID)
    history.record(RoutingChange("Remove channel", before: connected, after: removed))
    let restored = try history.undo(removed)
    try check(restored == connected, "node removal restores routes and state")
    history.clear(); try check(history.undoName == nil && history.redoName == nil, "clear undo on load")

    var layout = PipelineLayout()
    layout.positions[source.key] = PipelinePosition(x: 120, y: 80)
    layout.outputs = ["offline-recording"]
    connected.pipelineLayout = layout
    let data = try connected.data()
    try check(Session.decode(data) == connected, "layout round trip")
    try check(connected.dictionary()["pipelineLayout"] == nil, "layout omitted from native payload")
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json.removeValue(forKey: "pipelineLayout")
    try check(Session.decode(JSONSerialization.data(withJSONObject: json)).pipelineLayout == nil, "legacy session")
    json["pipelineLayout"] = ["positions": ["broken": "bad"], "outputs": 42]
    let recovered = try Session.decode(JSONSerialization.data(withJSONObject: json))
    try check(recovered.pipelineLayout == nil && recovered.audioSession == connected.audioSession, "bad layout cannot discard audio")
    layout.positions["bad"] = PipelinePosition(x: .infinity, y: 0)
    try check(layout.sanitized.positions["bad"] == nil, "nonfinite positions discarded")
    let g = PipelineGraph(connected)
    try check(g.nodes.contains(PipelineNodeID(.output, "offline-recording")), "unconnected saved output visible")
    try check(g.arranged() == PipelineGraph(connected).arranged(), "deterministic layout")

    // The exclusion belongs to the source identity, even via a differently named
    // strip and multiple bus paths. It must not suppress the other contributors.
    var mixed = original
    let caller = PipelineNodeID(.strip, mixed.strips[2].id)
    let monitor = PipelineNodeID(.bus, mixed.buses[0].id), call = PipelineNodeID(.bus, mixed.buses[1].id), stream = PipelineNodeID(.bus, mixed.buses[2].id)
    mixed.buses[0].sends = [Send(busID: call.rawID), Send(busID: stream.rawID)]
    mixed.buses[2].sends = [Send(busID: call.rawID)]
    mixed.routes = [OutputRoute(sourceID: call.rawID, destinationUID: "virtual-call")]
    let graph = PipelineGraph(mixed), trace = graph.trace(from: caller, in: mixed)
    try check(trace.excluded.contains(.send(monitor, call.rawID)) && trace.excluded.contains(.send(stream, call.rawID)), "transitive exclusions")
    try check(!trace.reached.contains(.route(mixed.routes[0].id)), "excluded contribution does not reach output")
    try check(graph.trace(from: source, in: mixed).reached.contains(.route(mixed.routes[0].id)), "other source reaches call output")
    mixed.strips[0].source = mixed.strips[2].source
    try check(PipelineGraph(mixed).trace(from: source, in: mixed).excluded.contains(.send(source, call.rawID)), "same source identity across different strips")
    let arranged = graph.arranged()
    try check(arranged[monitor.key]!.x < arranged[stream.key]!.x && arranged[stream.key]!.x < arranged[call.key]!.x, "bus DAG column order")
    mixed.buses[1].sends = [Send(busID: monitor.rawID)]
    do { _ = try mixed.validated(); fatalError("Pipeline accepted feedback") } catch {}
    mixed = original; mixed.buses[0].inserts = [.audioUnit(identifier: "61756678:68706173:6170706c", name: "Test")]
    mixed.buses[0].sends = [Send(busID: call.rawID)]
    do { _ = try mixed.validated(); fatalError("Pipeline accepted plugin bus send") } catch {}
    print("PASS: pipeline projection, scoped undo/redo, layout compatibility, audio payload separation, topology and source-identity mix-minus")
}

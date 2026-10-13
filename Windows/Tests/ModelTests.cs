using System.Text.Json.Nodes;
using MixingDesk.Models;
static class Tests
{
    static void Check(bool value, string message)
    {
        if (!value)
            throw new Exception(message);
    }
    static void Reject(Action action)
    {
        try
        {
            action();
        }
        catch (Exception e) when (e is InvalidDataException or FormatException or System.Text.Json.JsonException) { return; }
        throw new Exception("Invalid input accepted");
    }
    static void Main()
    {
        var s = Session.Starter();
        Check(s.Buses.Count == 3 && s.Strips.Count == 3, "Starter topology");
        Check(s.Strips[1].Sends[0].GainDB == -90, "Direct capture must not double monitor playback");
        Check(s.Encode() == Session.Decode(s.Encode()).Encode(), "Session round trip");
        var old = JsonNode.Parse(s.Encode())!;
        old.AsObject().Remove("outputProtectionEnabled");
        foreach (var strip in old["strips"]!.AsArray())
            strip!.AsObject().Remove("limiterEnabled");
        old["pipelineLayout"] = "future presentation format";
        var legacy = Session.Decode(old.ToJsonString());
        Check(legacy.OutputProtectionEnabled && legacy.Strips.All(x => x.LimiterEnabled) && legacy.PipelineLayout is null, "Legacy defaults and presentation isolation");
        var cycle = s.Clone();
        cycle.Buses[0].Sends.Add(new()
        {
            BusID = cycle.Buses[1].Id
        });
        cycle.Buses[1].Sends.Add(new()
        {
            BusID = cycle.Buses[0].Id
        });
        Reject(cycle.Validate);
        var duplicate = s.Clone();
        duplicate.Strips[1].Id = duplicate.Strips[0].Id;
        Reject(duplicate.Validate);
        var bad = s.Clone();
        bad.Strips[0].Pan = double.NaN;
        Reject(bad.Validate);
        var eq = new InsertSlot();
        eq.WriteEq(new()
        {
            MidGain = 3
        });
        Check(eq.ReadEq().MidGain == 3, "EQ roundtrip");
        s.Strips[0].Inserts.Add(eq);
        var history = new RoutingHistory();
        var before = s.Clone();
        s.Strips[0].Sends[1].GainDB = -6;
        history.Record("Send level", before, s);
        s.Strips[0].FaderDB = -12;
        eq.WriteEq(new()
        {
            MidGain = 8
        });
        var undone = history.Undo(s);
        Check(undone.Strips[0].Sends[1].GainDB == 0 && undone.Strips[0].FaderDB == -12 && undone.Strips[0].Inserts[0].ReadEq().MidGain == 8, "Routing undo must preserve live levels and plugin state");
        var redone = history.Redo(undone);
        Check(redone.Strips[0].Sends[1].GainDB == -6, "Routing redo");
        s.SelectMonitor("win:headphones", 2);
        Check(s.Routes.Single().DestinationUID == "win:headphones", "Monitor patch");
        s.SelectMonitor("win:usb", 1);
        Check(s.Routes.Count == 1 && s.Routes[0].Channels.Length == 1, "Monitor rebinding");
        const string id = "00112233445566778899AABBCCDDEEFF";
        var state = new Dictionary<string, object?> { ["version"] = 1L, ["classID"] = id, ["component"] = new byte[] { 0, 255, 3, 64 }, ["controller"] = new byte[] { 8, 9 }, ["parameters"] = new List<object?> { new Dictionary<string, object?> { ["id"] = 12L, ["value"] = .75 } } };
        var xml = Plist.Write(state);
        var json = Plist.VstJson(xml);
        Check(json["parameters"]![0]!["value"]!.GetValue<double>() == .75, "XML property list");
        Check(JsonNode.DeepEquals(json, Plist.VstJson(Plist.FromVstJson(json))), "VST3 state roundtrip");
        var fixture = Path.Combine(AppContext.BaseDirectory, "Fixtures", "vst-state.bplist");
        var binary = Plist.VstJson(File.ReadAllBytes(fixture));
        Check(JsonNode.DeepEquals(json, binary), "Mac binary property list");
        var slot = new InsertSlot { Format = "vst3", Identifier = id, State = File.ReadAllBytes(fixture) };
        slot.Validate();
        s.Strips[0].Inserts.Add(slot);
        Check(JsonNode.Parse(s.ForHost())!["strips"]![0]!["inserts"]![1]!["nativeState"] is JsonObject, "Native VST3 state transport");
        Reject(() => Plist.ValidateVst(Plist.Read(xml), "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"));
        var truncated = File.ReadAllBytes(fixture)[..20];
        Reject(() => Plist.Read(truncated));
        var au = new InsertSlot { Format = "au", Identifier = "61756678:12345678:12345678", State = xml };
        s.Strips[0].Inserts.Add(au);
        Check(Session.Decode(s.Encode()).Strips[0].Inserts[2].State!.SequenceEqual(xml), "Unavailable AU bytes must survive");
        PipelineTests.Run();
        Console.WriteLine("PASS: Windows session compatibility, validation, scoped routing undo, EQ, monitor binding, binary/XML plugin state, unavailable AU preservation.");
    }
}

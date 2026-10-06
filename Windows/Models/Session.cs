using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Diagnostics.CodeAnalysis;
namespace MixingDesk.Models;

public sealed class SourceBinding
{
    public string Kind { get; set; } = "device";
    public string DeviceUID { get; set; } = "";
    public string BundleID { get; set; } = "";
    public string ReturnBundleID { get; set; } = "";
    public int[] Channels { get; set; } = [0];
    [JsonIgnore] public string Key => Kind == "application" ? "app:" + BundleID : ReturnBundleID.Length > 0 ? "app:" + ReturnBundleID : "device:" + DeviceUID;
}
public sealed class EqSettings
{
    public int Version { get; set; } = 1;
    public double LowFrequency { get; set; } = 120;
    public double LowGain
    {
        get; set;
    }
    public double MidFrequency { get; set; } = 1000;
    public double MidGain
    {
        get; set;
    }
    public double MidQ { get; set; } = 1;
    public double HighFrequency { get; set; } = 8000;
    public double HighGain
    {
        get; set;
    }
    public double OutputGain
    {
        get; set;
    }
    public void Validate()
    {
        Session.Require(Version == 1 && new[] { LowFrequency, MidFrequency, HighFrequency }.All(x => Session.Range(x, 20, 20000)) &&
            new[] { LowGain, MidGain, HighGain, OutputGain }.All(x => Session.Range(x, -18, 18)) && Session.Range(MidQ, .1, 10), "Invalid EQ settings.");
    }
}
public sealed class InsertSlot
{
    public string Id { get; set; } = Session.NewId();
    public string Format { get; set; } = "builtin";
    public string Identifier { get; set; } = "local.mixingdesk.eq";
    public bool Bypassed
    {
        get; set;
    }
    public byte[]? State
    {
        get; set;
    }
    public string? Name
    {
        get; set;
    }
    [JsonIgnore] public string DisplayName => Format == "builtin" ? "Desk EQ" : Name ?? Format.ToUpperInvariant();
    public EqSettings ReadEq()
    {
        var eq = State is null ? new EqSettings() : JsonSerializer.Deserialize<EqSettings>(State, Session.Options) ?? throw new InvalidDataException("Invalid EQ state.");
        eq.Validate();
        return eq;
    }
    public void WriteEq(EqSettings eq)
    {
        eq.Validate();
        State = JsonSerializer.SerializeToUtf8Bytes(eq, Session.Options);
    }
    public void Validate()
    {
        Session.Require(State is null || State.Length <= 16 * 1024 * 1024, "Plugin state exceeds 16 MB.");
        if (Format == "builtin")
        {
            Session.Require(Identifier == "local.mixingdesk.eq", "Unknown built-in effect.");
            ReadEq();
            return;
        }
        if (Format == "vst3")
        {
            Session.Require(Regex.IsMatch(Identifier, "^[0-9A-F]{32}$"), "Invalid VST3 class identifier.");
            if (State is not null)
                Plist.ValidateVst(Plist.Read(State), Identifier);
            return;
        }
        Session.Require(Format == "au" && Regex.IsMatch(Identifier, "^(61756678|61756d66):[0-9a-f]{8}:[0-9a-f]{8}$"), "Unsupported insert.");
        if (State is not null)
            Session.Require(Plist.Read(State) is Dictionary<string, object?>, "Invalid Audio Unit state.");
    }
}
public sealed class Send
{
    public string BusID { get; set; } = "";
    public double GainDB
    {
        get; set;
    }
    public bool PreFader
    {
        get; set;
    }
}
public sealed class ChannelStrip
{
    public string Id { get; set; } = Session.NewId();
    public string Name { get; set; } = "Channel";
    public string Color { get; set; } = "teal";
    public string Role { get; set; } = "generic";
    public SourceBinding Source { get; set; } = new();
    public double TrimDB
    {
        get; set;
    }
    public double FaderDB
    {
        get; set;
    }
    public double Pan
    {
        get; set;
    }
    public bool Polarity
    {
        get; set;
    }
    public bool Muted
    {
        get; set;
    }
    public bool Solo
    {
        get; set;
    }
    public bool LimiterEnabled { get; set; } = true;
    public List<Send> Sends { get; set; } = [];
    public List<InsertSlot> Inserts { get; set; } = [];
}
public sealed class Bus
{
    public string Id { get; set; } = Session.NewId();
    public string Name { get; set; } = "Bus";
    public string Kind { get; set; } = "mix";
    public double GainDB
    {
        get; set;
    }
    public bool Muted
    {
        get; set;
    }
    public string ExcludedStripID { get; set; } = "";
    public List<Send> Sends { get; set; } = [];
    public List<InsertSlot> Inserts { get; set; } = [];
}
public sealed class OutputRoute
{
    public string Id { get; set; } = Session.NewId();
    public string SourceKind { get; set; } = "bus";
    public string SourceID { get; set; } = "";
    public bool PreFader
    {
        get; set;
    }
    public string DestinationUID { get; set; } = "";
    public int[] Channels { get; set; } = [0, 1];
    public double GainDB
    {
        get; set;
    }
}
public sealed class PipelinePosition
{
    public double X
    {
        get; set;
    }
    public double Y
    {
        get; set;
    }
}
public sealed class PipelineLayout
{
    public Dictionary<string, PipelinePosition> Positions { get; set; } = [];
    public List<string> Outputs { get; set; } = [];
    public void Sanitize()
    {
        Positions = (Positions ?? []).Where(p => p.Key.Length > 0 && p.Value is not null && Session.Range(p.Value.X, 0, 999999) && Session.Range(p.Value.Y, 0, 999999)).ToDictionary();
        Outputs = (Outputs ?? []).Where(s => !string.IsNullOrEmpty(s)).Distinct().Order().ToList();
    }
}
public sealed class Session
{
    public static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, WriteIndented = true, DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };
    public static string NewId() => Guid.NewGuid().ToString().ToUpperInvariant();
    public int Version { get; set; } = 1;
    public string Name { get; set; } = "My Desk";
    public string MonitorDeviceUID { get; set; } = "";
    public int BufferFrames { get; set; } = 128;
    public string MonitoringMode { get; set; } = "mixer";
    public bool OutputProtectionEnabled { get; set; } = true;
    public List<ChannelStrip> Strips { get; set; } = [];
    public List<Bus> Buses { get; set; } = [];
    public List<OutputRoute> Routes { get; set; } = [];
    public PipelineLayout? PipelineLayout
    {
        get; set;
    }
    [JsonIgnore] public IEnumerable<InsertSlot> AllInserts => Strips.SelectMany(x => x.Inserts).Concat(Buses.SelectMany(x => x.Inserts));
    public static bool Range(double x, double lo, double hi) => double.IsFinite(x) && x >= lo && x <= hi;
    public static void Require([DoesNotReturnIf(false)] bool test, string message)
    {
        if (!test)
            throw new InvalidDataException(message);
    }
    public static Session Starter()
    {
        var s = new Session();
        s.Buses = [new() { Name = "Monitor", Kind = "monitor" }, new() { Name = "Call", Kind = "call" }, new() { Name = "Stream" }];
        s.Strips = [new() { Name = "Microphone" }, new() { Name = "Application", Color = "purple", Source = new() { Kind = "application", Channels = [0, 1] } }, new() { Name = "Call Return", Color = "blue", Role = "callReturn", Source = new() { Kind = "application", Channels = [0, 1] } }];
        foreach (var strip in s.Strips)
            strip.Sends = s.Buses.Select(b => new Send { BusID = b.Id, GainDB = b.Kind == "monitor" && strip.Source.Kind == "application" ? -90 : 0 }).ToList();
        s.Buses[1].ExcludedStripID = s.Strips[2].Id;
        return s;
    }
    public void Validate()
    {
        Require(Version == 1, "Unsupported session version.");
        Require(Strips is not null && Buses is not null && Routes is not null, "Invalid session lists.");
        Require(Strips!.Count <= 64 && Buses!.Count <= 16 && Routes!.Count <= 512, "Capacity: 64 strips, 16 buses, 512 output routes.");
        Require(new[] { 32, 64, 128, 256, 512, 1024, 2048, 4096 }.Contains(BufferFrames), "Invalid buffer size.");
        Require(MonitoringMode is "mixer" or "directGuitar", "Invalid monitoring mode.");
        var ids = new HashSet<string>();
        void Id(string id) => Require(!string.IsNullOrEmpty(id) && ids.Add(id), "Session identifiers must be unique.");
        foreach (var id in Strips.Select(x => x.Id).Concat(Buses.Select(x => x.Id)).Concat(Routes.Select(x => x.Id)).Concat(AllInserts.Select(x => x.Id)))
            Id(id);
        Require(Buses.Count(b => b.Kind == "monitor") == 1, "Exactly one Monitor bus is required.");
        var busIDs = Buses.Select(x => x.Id).ToHashSet();
        var stripIDs = Strips.Select(x => x.Id).ToHashSet();
        void Channels(int[] c) => Require(c is not null && c.Length is 1 or 2 && c.All(x => x >= 0 && x < 512) && c.Distinct().Count() == c.Length, "Choose one channel or two different stereo channels.");
        void Sends(List<Send> sends)
        {
            Require(sends is not null && sends.Count <= 16 && sends.Select(x => x.BusID).Distinct().Count() == sends.Count, "Duplicate or excessive sends.");
            foreach (var send in sends!)
                Require(busIDs.Contains(send.BusID) && Range(send.GainDB, -90, 24), "Invalid send.");
        }
        void Inserts(List<InsertSlot> slots)
        {
            Require(slots is not null && slots.Count <= 4, "Up to four inserts per channel or bus.");
            foreach (var slot in slots!)
                slot.Validate();
        }
        var taps = new HashSet<string>();
        var returns = new HashSet<string>();
        foreach (var strip in Strips)
        {
            Require(Range(strip.TrimDB, -90, 24) && Range(strip.FaderDB, -90, 24) && Range(strip.Pan, -1, 1), "Invalid channel levels.");
            Require(strip.Source.Kind is "device" or "application", "Invalid source type.");
            Channels(strip.Source.Channels);
            if (strip.Source.Kind == "application" && strip.Source.BundleID.Length > 0)
                taps.Add(strip.Source.BundleID);
            if (strip.Source.ReturnBundleID.Length > 0)
                returns.Add(strip.Source.ReturnBundleID);
            Sends(strip.Sends);
            Inserts(strip.Inserts);
        }
        Require(!taps.Overlaps(returns), "An application cannot use both direct capture and a virtual return.");
        foreach (var bus in Buses)
        {
            Require(Range(bus.GainDB, -90, 24) && bus.Kind is "monitor" or "call" or "mix", "Invalid bus.");
            Require(bus.ExcludedStripID.Length == 0 || stripIDs.Contains(bus.ExcludedStripID), "The excluded return source is missing.");
            Sends(bus.Sends);
            Inserts(bus.Inserts);
            Require(!bus.Inserts.Any(x => x.Format != "builtin") || bus.Sends.Count == 0, "Plugin buses cannot send to other buses.");
        }
        var visited = new HashSet<string>();
        var visiting = new HashSet<string>();
        void Visit(string id)
        {
            Require(!visiting.Contains(id), "Routing would create a feedback cycle.");
            if (!visited.Add(id))
                return;
            visiting.Add(id);
            foreach (var send in Buses.First(x => x.Id == id).Sends)
                Visit(send.BusID);
            visiting.Remove(id);
        }
        foreach (var bus in Buses)
            Visit(bus.Id);
        foreach (var route in Routes)
        {
            Require(route.SourceKind is "bus" or "strip" && (route.SourceKind == "bus" ? busIDs : stripIDs).Contains(route.SourceID), "Invalid output route source.");
            Require(Range(route.GainDB, -90, 24), "Invalid route gain.");
            Channels(route.Channels);
        }
        PipelineLayout?.Sanitize();
    }
    public string Encode()
    {
        Validate();
        return JsonSerializer.Serialize(this, Options);
    }
    public static Session Decode(string text)
    {
        Require(text.Length <= 128 * 1024 * 1024, "Session exceeds 128 MB.");
        var node = JsonNode.Parse(text)!.AsObject();
        var layout = node["pipelineLayout"]?.DeepClone();
        node.Remove("pipelineLayout");
        // Required top-level fields protect against accidentally treating arbitrary
        // JSON as a valid empty session; optional v1 additions keep their defaults.
        foreach (var key in new[] { "version", "name", "monitorDeviceUID", "bufferFrames", "monitoringMode", "strips", "buses", "routes" })
            Require(node.ContainsKey(key), "Missing session field: " + key);
        var session = node.Deserialize<Session>(Options) ?? throw new InvalidDataException("Invalid session.");
        try
        {
            session.PipelineLayout = layout?.Deserialize<PipelineLayout>(Options);
            session.PipelineLayout?.Sanitize();
        }
        catch (Exception e) when (e is JsonException or InvalidOperationException or NullReferenceException) { session.PipelineLayout = null; }
        session.Validate();
        return session;
    }
    public Session Clone() => Decode(Encode());
    public string ForHost()
    {
        var node = JsonNode.Parse(Encode())!.AsObject();
        node.Remove("pipelineLayout");
        foreach (var kind in new[] { "strips", "buses" })
        foreach (var owner in node[kind]!.AsArray())
        foreach (var slot in owner!["inserts"]!.AsArray())
            if (slot!["format"]!.GetValue<string>() == "vst3" && slot["state"] is not null)
                slot["nativeState"] = Plist.VstJson(Convert.FromBase64String(slot["state"]!.GetValue<string>()));
        return node.ToJsonString(Options);
    }
    public void CaptureStates(JsonObject states)
    {
        foreach (var slot in AllInserts.Where(s => s.Format == "vst3"))
        if (states[slot.Id] is JsonObject state)
            slot.State = Plist.FromVstJson(state);
    }
    public void SelectMonitor(string uid, int channels)
    {
        var old = MonitorDeviceUID;
        MonitorDeviceUID = uid;
        var monitor = Buses.Single(x => x.Kind == "monitor");
        Routes.RemoveAll(r => r.SourceKind == "bus" && r.SourceID == monitor.Id && r.DestinationUID == old);
        if (uid.Length > 0 && !Routes.Any(r => r.SourceKind == "bus" && r.SourceID == monitor.Id && r.DestinationUID == uid))
            Routes.Add(new()
            {
                SourceID = monitor.Id,
                DestinationUID = uid,
                Channels = channels > 1 ? [0, 1] : [0]
            });
    }
    public void RemoveStrip(string id)
    {
        Strips.RemoveAll(x => x.Id == id);
        Routes.RemoveAll(x => x.SourceKind == "strip" && x.SourceID == id);
        foreach (var b in Buses.Where(x => x.ExcludedStripID == id))
            b.ExcludedStripID = "";
    }
    public void RemoveBus(string id)
    {
        Require(Buses.All(x => x.Id != id || x.Kind != "monitor"), "The Monitor bus cannot be removed.");
        Buses.RemoveAll(x => x.Id == id);
        Routes.RemoveAll(x => x.SourceKind == "bus" && x.SourceID == id);
        foreach (var sends in Strips.Select(x => x.Sends).Concat(Buses.Select(x => x.Sends)))
            sends.RemoveAll(x => x.BusID == id);
    }
}

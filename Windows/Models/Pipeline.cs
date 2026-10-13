namespace MixingDesk.Models;

public sealed record PipelineNode(string Kind, string Id)
{
    public string Key => Kind + ":" + Id;
}
public sealed record PipelineEdge(string Key, PipelineNode Source, PipelineNode Destination, double GainDB, bool PreFader, int[] Channels, string? RouteId = null)
{
    public bool Off => GainDB <= -90;
}
public sealed class PipelineTrace
{
    public HashSet<string> Reached { get; } = [];
    public HashSet<string> Excluded { get; } = [];
}
// Presentation of the session, never a separate audio graph.
public sealed class PipelineGraph
{
    public List<PipelineNode> Nodes { get; } = [];
    public List<PipelineEdge> Edges { get; } = [];
    public PipelineGraph(Session session)
    {
        Nodes.AddRange(session.Strips.Select(s => new PipelineNode("strip", s.Id)));
        Nodes.AddRange(session.Buses.Select(b => new PipelineNode("bus", b.Id)));
        Nodes.AddRange(new[] { session.MonitorDeviceUID }.Concat(session.Routes.Select(r => r.DestinationUID)).Concat(session.PipelineLayout?.Outputs ?? []).Where(x => x.Length > 0).Distinct().Select(x => new PipelineNode("output", x)));
        foreach (var node in Nodes.Where(n => n.Kind != "output"))
            foreach (var send in Sends(session, node))
                Edges.Add(new("send:" + node.Key + ":" + send.BusID, node, new("bus", send.BusID), send.GainDB, node.Kind == "strip" && send.PreFader, []));
        Edges.AddRange(session.Routes.Select(r => new PipelineEdge("route:" + r.Id, new(r.SourceKind, r.SourceID), new("output", r.DestinationUID), r.GainDB, r.SourceKind == "strip" && r.PreFader, r.Channels, r.Id)));
    }
    public Dictionary<string, PipelinePosition> Arrange()
    {
        var ranks = Nodes.ToDictionary(n => n.Key, n => n.Kind == "strip" ? 0 : 1);
        for (int i = 0; i < Nodes.Count; i++)
        {
            bool changed = false;
            foreach (var edge in Edges.Where(e => e.Source.Kind == "bus" && e.Destination.Kind == "bus"))
                if (ranks[edge.Destination.Key] <= ranks[edge.Source.Key])
                {
                    ranks[edge.Destination.Key] = ranks[edge.Source.Key] + 1;
                    changed = true;
                }
            if (!changed)
                break;
        }
        int output = Nodes.Where(n => n.Kind == "bus").Select(n => ranks[n.Key]).DefaultIfEmpty(1).Max() + 1;
        var rows = new Dictionary<int, int>();
        var result = new Dictionary<string, PipelinePosition>();
        foreach (var node in Nodes)
        {
            int column = node.Kind == "output" ? output : ranks[node.Key];
            int row = rows.GetValueOrDefault(column);
            rows[column] = row + 1;
            result[node.Key] = new()
            {
                X = 50 + column * 350,
                Y = 55 + row * 250
            };
        }
        return result;
    }
    public static List<Send> Sends(Session s, PipelineNode source) => source.Kind == "strip" ? s.Strips.Single(x => x.Id == source.Id).Sends : s.Buses.Single(x => x.Id == source.Id).Sends;
    public static bool Excludes(Session s, string busId, SourceBinding source)
    {
        var bus = s.Buses.FirstOrDefault(b => b.Id == busId);
        var excluded = s.Strips.FirstOrDefault(x => x.Id == bus?.ExcludedStripID);
        return excluded is not null && excluded.Source.Key == source.Key;
    }
    public bool DirectlyExcluded(Session s, PipelineEdge e) => e.Source.Kind == "strip" && e.Destination.Kind == "bus" && Excludes(s, e.Destination.Id, s.Strips.Single(x => x.Id == e.Source.Id).Source);
    public PipelineTrace Trace(Session s, PipelineNode start)
    {
        var trace = new PipelineTrace();
        var visited = new HashSet<string>();
        var strip = s.Strips.FirstOrDefault(x => start.Kind == "strip" && x.Id == start.Id);
        void Visit(PipelineNode node)
        {
            if (!visited.Add(node.Key))
                return;
            foreach (var edge in Edges.Where(e => e.Source == node))
            {
                trace.Reached.Add(edge.Key);
                bool excluded = strip is not null && edge.Destination.Kind == "bus" && Excludes(s, edge.Destination.Id, strip.Source);
                if (strip is not null && edge.Destination.Kind == "output" && s.Buses.Any(b => b.Id == node.Id && b.Kind == "monitor"))
                    excluded |= (s.Strips.Any(x => x.Solo) && !strip.Solo) || (s.MonitoringMode == "directGuitar" && strip.Role == "guitar");
                if (excluded)
                    trace.Excluded.Add(edge.Key);
                else if (!edge.Off)
                    Visit(edge.Destination);
            }
        }
        Visit(start);
        return trace;
    }
    public static string? ConnectionProblem(Session s, PipelineNode source, PipelineNode target)
    {
        if (source.Kind == "output" || target.Kind == "strip")
            return "Connect a channel or bus to a bus or output.";
        if (source == target)
            return "A bus cannot feed itself.";
        if (target.Kind == "output")
            return null;
        try
        {
            var candidate = s.Clone();
            var sends = Sends(candidate, source);
            if (sends.All(x => x.BusID != target.Id))
                sends.Add(new()
                {
                    BusID = target.Id
                });
            candidate.Validate();
            return null;
        }
        catch (Exception e) { return e.Message; }
    }
    public static void Remove(Session s, PipelineNode node)
    {
        if (node.Kind == "strip")
            s.RemoveStrip(node.Id);
        else if (node.Kind == "bus")
            s.RemoveBus(node.Id);
        else
        {
            s.Routes.RemoveAll(r => r.DestinationUID == node.Id);
            s.PipelineLayout?.Outputs.Remove(node.Id);
            if (s.MonitorDeviceUID == node.Id)
                s.MonitorDeviceUID = "";
        }
        s.PipelineLayout?.Positions.Remove(node.Key);
    }
}

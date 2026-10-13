using MixingDesk.Models;
static class PipelineTests
{
    static void Check(bool yes, string message)
    {
        if (!yes)
            throw new Exception(message);
    }
    public static void Run()
    {
        var s = Session.Starter();
        for (int i = 0; i < s.Strips.Count; i++)
        {
            s.Strips[i].Source = new()
            {
                DeviceUID = "input:" + i
            };
            s.Strips[i].Sends.Clear();
        }
        var source = new PipelineNode("strip", s.Strips[0].Id);
        var monitor = new PipelineNode("bus", s.Buses[0].Id);
        var call = new PipelineNode("bus", s.Buses[1].Id);
        var stream = new PipelineNode("bus", s.Buses[2].Id);
        s.Strips[0].Sends.Add(new()
        {
            BusID = stream.Id
        });
        s.Buses[2].Sends.Add(new()
        {
            BusID = call.Id
        });
        s.Buses[1].ExcludedStripID = s.Strips[0].Id;
        s.SelectMonitor("headphones", 2);
        s.Routes.Add(new()
        {
            SourceID = call.Id,
            DestinationUID = "call cable"
        });
        s.Validate();
        var graph = new PipelineGraph(s);
        var trace = graph.Trace(s, source);
        Check(trace.Excluded.Contains(graph.Edges.Single(e => e.Source == stream).Key), "Transitive mix-minus must identify the excluded edge.");
        Check(!trace.Reached.Contains("route:" + s.Routes.Last().Id), "Trace must stop at an exclusion.");
        Check(PipelineGraph.ConnectionProblem(s, call, stream) is not null, "Reject cycles before creating a connection.");
        Check(PipelineGraph.ConnectionProblem(s, monitor, monitor) is not null, "Reject self loops.");
        Check(PipelineGraph.ConnectionProblem(s, source, monitor) is null, "Allow strip to monitor.");
        var arranged = graph.Arrange();
        Check(arranged[call.Key].X > arranged[stream.Key].X, "Arrange downstream buses after their sources.");
        s.Strips[1].Source.DeviceUID = s.Strips[0].Source.DeviceUID;
        Check(PipelineGraph.Excludes(s, call.Id, s.Strips[1].Source), "Mix-minus follows source identity, including copies.");
        var beforeAudio = s.ForHost();
        s.PipelineLayout = new()
        {
            Positions = arranged,
            Outputs = ["saved offline output"]
        };
        Check(s.ForHost() == beforeAudio, "Presentation metadata must not alter native audio configuration.");
        Check(Session.Decode(s.Encode()).PipelineLayout!.Positions.Count == arranged.Count, "Positions survive export/import.");
        var history = new RoutingHistory();
        var before = s.Clone();
        PipelineGraph.Remove(s, stream);
        history.Record("Remove bus", before, s);
        s.Strips[0].FaderDB = -8;
        var restored = history.Undo(s);
        Check(restored.Buses.Any(b => b.Id == stream.Id) && restored.Strips[0].Sends.Any(x => x.BusID == stream.Id), "Undo restores node and its cables.");
        Check(restored.Strips[0].FaderDB == -8, "Routing undo preserves current faders.");
        PipelineGraph.Remove(s, new("output", "headphones"));
        Check(s.MonitorDeviceUID == "" && s.Routes.All(r => r.DestinationUID != "headphones"), "Removing monitor output clears its assignment and routes.");
        try
        {
            PipelineGraph.Remove(s, monitor);
            throw new Exception("Monitor removal succeeded");
        }
        catch (InvalidDataException) { }
        s = Session.Starter();
        s.Strips[0].Source.DeviceUID = "microphone";
        s.Strips[1].Source.BundleID = "music";
        s.Strips[0].Sends = [new() { BusID = s.Buses[0].Id }];
        s.Strips[0].Solo = false;
        s.Strips[1].Solo = true;
        s.SelectMonitor("headphones", 2);
        graph = new(s);
        trace = graph.Trace(s, new("strip", s.Strips[0].Id));
        Check(trace.Excluded.Contains("route:" + s.Routes[0].Id), "Solo excludes only the monitor output from an un-soloed source trace.");
        Console.WriteLine("PASS: pipeline connection validation, arrangement, transitive trace, metadata isolation, node removal and scoped undo.");
    }
}

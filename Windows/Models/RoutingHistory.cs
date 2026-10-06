using System.Text.Json.Nodes;
namespace MixingDesk.Models;

public sealed class RoutingHistory
{
    sealed record Change(string Name, JsonObject Before, JsonObject After);
    readonly List<Change> past = [], future = [];
    public bool CanUndo => past.Count > 0;
    public bool CanRedo => future.Count > 0;
    public void Clear()
    {
        past.Clear();
        future.Clear();
    }
    public void Record(string name, Session before, Session after)
    {
        var a = JsonNode.Parse(before.Encode())!.AsObject();
        var b = JsonNode.Parse(after.Encode())!.AsObject();
        if (JsonNode.DeepEquals(a, b))
            return;
        past.Add(new(name, a, b));
        if (past.Count > 100)
            past.RemoveAt(0);
        future.Clear();
    }
    // Apply only the changed fields, merging entity arrays by identity. A routing
    // undo must never restore an old fader or overwrite newer plugin snapshots.
    static JsonNode? Merge(JsonNode? from, JsonNode? to, JsonNode? live, string key = "")
    {
        if (JsonNode.DeepEquals(from, to))
            return live?.DeepClone();
        if (from is JsonObject a && to is JsonObject b && live is JsonObject c)
        {
            var result = (JsonObject)c.DeepClone();
            foreach (var name in a.Select(p => p.Key).Union(b.Select(p => p.Key)))
            if (!JsonNode.DeepEquals(a[name], b[name]))
            {
                if (!b.ContainsKey(name))
                    result.Remove(name);
                else
                    result[name] = Merge(a[name], b[name], c[name], name);
            }
            return result;
        }
        if (from is JsonArray old && to is JsonArray next && live is JsonArray current && key is "strips" or "buses" or "routes" or "sends" or "inserts")
        {
            string idKey = key == "sends" ? "busID" : "id";
            string Id(JsonNode? n) => n![idKey]!.GetValue<string>();
            var result = (JsonArray)current.DeepClone();
            var olds = old.ToDictionary(Id);
            var news = next.ToDictionary(Id);
            foreach (var node in result.ToArray())
            if (olds.ContainsKey(Id(node)) && !news.ContainsKey(Id(node)))
                result.Remove(node);
            for (int i = 0; i < next.Count; ++i)
            {
                var node = next[i];
                var id = Id(node);
                var index = result.Select((x, j) => (x, j)).Where(p => Id(p.x) == id).Select(p => p.j).DefaultIfEmpty(-1).First();
                if (!olds.TryGetValue(id, out var previous))
                {
                    if (index < 0)
                        result.Insert(Math.Min(i, result.Count), node!.DeepClone());
                }
                else if (!JsonNode.DeepEquals(previous, node))
                {
                    Session.Require(index >= 0, "This routing edit refers to an item that has been removed.");
                    result[index] = Merge(previous, node, result[index], key);
                }
            }
            return result;
        }
        return to?.DeepClone();
    }
    public Session Undo(Session current) => Apply(current, past, future, true);
    public Session Redo(Session current) => Apply(current, future, past, false);
    static Session Apply(Session current, List<Change> source, List<Change> destination, bool backwards)
    {
        if (source.Count == 0)
            return current;
        var change = source[^1];
        var live = JsonNode.Parse(current.Encode())!.AsObject();
        var next = Merge(backwards ? change.After : change.Before, backwards ? change.Before : change.After, live)!.AsObject();
        var session = Session.Decode(next.ToJsonString());
        source.RemoveAt(source.Count - 1);
        destination.Add(backwards ? new(change.Name, next, live) : new(change.Name, live, next));
        return session;
    }
}

using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.Json.Nodes;
using System.Xml;
using System.Xml.Linq;
namespace MixingDesk.Models;

// Existing Mac sessions contain base64 Apple property lists. Read binary and
// XML containers; write standard XML accepted by Foundation on the Mac. Plugin
// component/controller bytes remain opaque and are never reinterpreted.
public static class Plist
{
    public static object? Read(byte[] bytes)
    {
        Session.Require(bytes.Length <= 16 * 1024 * 1024, "Property list exceeds 16 MB.");
        if (bytes.AsSpan().StartsWith("bplist00"u8))
            return new BinaryReader(bytes).Read();
        using var stream = new MemoryStream(bytes);
        using var reader = XmlReader.Create(stream, new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null, MaxCharactersInDocument = 32 * 1024 * 1024 });
        var doc = XDocument.Load(reader);
        Session.Require(doc.Root?.Name == "plist", "Invalid property list.");
        return Parse(doc.Root!.Elements().Single(), 0);
    }
    static object? Parse(XElement e, int depth)
    {
        Session.Require(depth < 64, "Property list is too deeply nested.");
        switch (e.Name.LocalName)
        {
            case "dict":
                var nodes = e.Elements().ToArray();
                Session.Require(nodes.Length % 2 == 0, "Invalid property-list dictionary.");
                var d = new Dictionary<string, object?>();
                for (int i = 0; i < nodes.Length; i += 2)
                {
                    Session.Require(nodes[i].Name == "key", "Invalid dictionary key.");
                    d.Add(nodes[i].Value, Parse(nodes[i + 1], depth + 1));
                }
                return d;
            case "array":
                return e.Elements().Select(x => Parse(x, depth + 1)).ToList();
            case "string":
                return e.Value;
            case "data":
                return Convert.FromBase64String(e.Value);
            case "integer":
                return long.Parse(e.Value, CultureInfo.InvariantCulture);
            case "real":
                return double.Parse(e.Value, CultureInfo.InvariantCulture);
            case "true":
                return true;
            case "false":
                return false;
            case "date":
                return DateTime.Parse(e.Value, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
            default:
                throw new InvalidDataException("Unsupported property-list element.");
        }
    }
    public static Dictionary<string, object?> ValidateVst(object? value, string id)
    {
        Session.Require(value is Dictionary<string, object?>, "Invalid VST3 state.");
        var d = (Dictionary<string, object?>)value!;
        Session.Require(d.TryGetValue("version", out var version) && Convert.ToInt64(version, CultureInfo.InvariantCulture) == 1 && d.GetValueOrDefault("classID") as string == id && d.GetValueOrDefault("component") is byte[] && (!d.ContainsKey("controller") || d["controller"] is byte[]) && d.GetValueOrDefault("parameters") is List<object?>, "Invalid or mismatched VST3 state.");
        var parameters = (List<object?>)d["parameters"]!;
        Session.Require(parameters.Count <= 32768, "Too many VST3 parameters.");
        foreach (var item in parameters)
        {
            Session.Require(item is Dictionary<string, object?>, "Invalid parameter state.");
            var p = (Dictionary<string, object?>)item!;
            double param = Convert.ToDouble(p["id"], CultureInfo.InvariantCulture), v = Convert.ToDouble(p["value"], CultureInfo.InvariantCulture);
            Session.Require(Session.Range(param, 0, uint.MaxValue) && param == Math.Truncate(param) && Session.Range(v, 0, 1), "Invalid normalized VST3 parameter.");
        }
        return d;
    }
    public static JsonObject VstJson(byte[] bytes)
    {
        var raw = Read(bytes) as Dictionary<string, object?> ?? throw new InvalidDataException("Invalid VST3 state.");
        var d = ValidateVst(raw, (string)raw["classID"]!);
        var result = new JsonObject { ["version"] = 1, ["classID"] = (string)d["classID"]!, ["component"] = Convert.ToBase64String((byte[])d["component"]!) };
        if (d.TryGetValue("controller", out var c))
            result["controller"] = Convert.ToBase64String((byte[])c!);
        var parameters = new JsonArray();
        foreach (var item in (List<object?>)d["parameters"]!)
        {
            var p = (Dictionary<string, object?>)item!;
            parameters.Add(new JsonObject { ["id"] = Convert.ToUInt32(p["id"]), ["value"] = Convert.ToDouble(p["value"]) });
        }
        result["parameters"] = parameters;
        return result;
    }
    public static byte[] FromVstJson(JsonObject state)
    {
        var d = new Dictionary<string, object?>
        {
            ["version"] = 1L,
            ["classID"] = state["classID"]!.GetValue<string>(),
            ["component"] = Convert.FromBase64String(state["component"]!.GetValue<string>()),
            ["parameters"] = state["parameters"]!.AsArray().Select(p => (object?)new Dictionary<string, object?> { ["id"] = long.Parse(p!["id"]!.ToJsonString(), CultureInfo.InvariantCulture), ["value"] = p["value"]!.GetValue<double>() }).ToList()
        };
        if (state["controller"] is not null)
            d["controller"] = Convert.FromBase64String(state["controller"]!.GetValue<string>());
        ValidateVst(d, (string)d["classID"]!);
        var bytes = Write(d);
        Session.Require(bytes.Length <= 16 * 1024 * 1024, "VST3 state exceeds 16 MB.");
        return bytes;
    }
    public static byte[] Write(object? value)
    {
        XElement Element(object? x) => x switch
        {
            Dictionary<string, object?> d => new XElement("dict", d.SelectMany(p => new[] { new XElement("key", p.Key), Element(p.Value) })),
            List<object?> a => new XElement("array", a.Select(Element)),
            byte[] b => new XElement("data", Convert.ToBase64String(b)),
            string s => new XElement("string", s),
            bool b => new XElement(b ? "true" : "false"),
            double n => new XElement("real", n.ToString("R", CultureInfo.InvariantCulture)),
            long n => new XElement("integer", n.ToString(CultureInfo.InvariantCulture)),
            DateTime t => new XElement("date", t.ToUniversalTime().ToString("O")),
            _ => throw new InvalidDataException("Unsupported property-list value.")
        };
        var doc = new XDocument(new XDeclaration("1.0", "utf-8", null), new XElement("plist", new XAttribute("version", "1.0"), Element(value)));
        using var output = new MemoryStream();
        doc.Save(output);
        return output.ToArray();
    }
    sealed class BinaryReader(byte[] data)
    {
        int offsetSize, referenceSize; ulong objects, root, table; readonly HashSet<ulong> active = []; readonly Dictionary<ulong, object?> cache = []; int visits;
        ulong UInt(int offset, int count)
        {
            Session.Require(count is >= 1 and <= 8 && offset >= 0 && offset <= data.Length - count, "Invalid property-list offset.");
            ulong n = 0;
            for (int i = 0; i < count; ++i)
                n = (n << 8) | data[offset + i];
            return n;
        }
        int Index(ulong offset)
        {
            Session.Require(offset < (ulong)data.Length, "Property-list offset is out of bounds.");
            return checked((int)offset);
        }
        public object? Read()
        {
            Session.Require(data.Length >= 40, "Truncated binary property list.");
            int t = data.Length - 32;
            offsetSize = data[t + 6];
            referenceSize = data[t + 7];
            objects = UInt(t + 8, 8);
            root = UInt(t + 16, 8);
            table = UInt(t + 24, 8);
            Session.Require(offsetSize is >= 1 and <= 8 && referenceSize is >= 1 and <= 8 && objects > 0 && objects <= 1000000 && root < objects && table >= 8 && table <= (ulong)t && objects <= ((ulong)t - table) / (ulong)offsetSize, "Invalid property-list trailer.");
            return Object(root, 0);
        }
        object? Object(ulong id, int depth)
        {
            Session.Require(depth < 64 && id < objects && ++visits <= 2000000, "Invalid or excessive property-list references.");
            if (cache.TryGetValue(id, out var cached))
                return cached;
            Session.Require(active.Add(id), "Cyclic property list.");
            int p = Index(UInt(Index(table + id * (ulong)offsetSize), offsetSize));
            Session.Require(p >= 8 && (ulong)p < table, "Invalid property-list object.");
            int marker = data[p++], type = marker >> 4, small = marker & 15;
            int Length()
            {
                if (small != 15)
                    return small;
                Session.Require(p < (int)table && (data[p] >> 4) == 1 && (data[p] & 15) <= 3, "Invalid property-list length.");
                int width = 1 << (data[p++] & 15);
                ulong n = UInt(p, width);
                p += width;
                Session.Require(n <= 16 * 1024 * 1024, "Property-list object is too large.");
                return (int)n;
            }
            byte[] Bytes(int count)
            {
                Session.Require(count >= 0 && p <= (long)table - count, "Truncated property-list object.");
                return data.AsSpan(p, count).ToArray();
            }
            object? result;
            switch (type)
            {
                case 0:
                    result = small switch
                    {
                        0 => null,
                        8 => false,
                        9 => true,
                        _ => throw new InvalidDataException("Unsupported property-list scalar.")
                    };
                    break;
                case 1:
                    Session.Require(small <= 3, "Unsupported property-list integer.");
                    result = unchecked((long)UInt(p, 1 << small));
                    break;
                case 2:
                    Session.Require(small is 2 or 3, "Unsupported property-list real.");
                    result = small == 2 ? (double)BitConverter.Int32BitsToSingle(unchecked((int)UInt(p, 4))) : BitConverter.Int64BitsToDouble(unchecked((long)UInt(p, 8)));
                    break;
                case 3:
                    Session.Require(small == 3, "Invalid property-list date.");
                    result = new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(BitConverter.Int64BitsToDouble(unchecked((long)UInt(p, 8))));
                    break;
                case 4:
                    result = Bytes(Length());
                    break;
                case 5:
                    result = Encoding.ASCII.GetString(Bytes(Length()));
                    break;
                case 6:
                    result = Encoding.BigEndianUnicode.GetString(Bytes(checked(Length() * 2)));
                    break;
                case 10:
                    {
                        int n = Length();
                        Bytes(checked(n * referenceSize));
                        var list = new List<object?>(n);
                        for (int i = 0; i < n; ++i)
                            list.Add(Object(UInt(p + i * referenceSize, referenceSize), depth + 1));
                        result = list;
                        break;
                    }
                case 13:
                    {
                        int n = Length();
                        Bytes(checked(n * referenceSize * 2));
                        var dict = new Dictionary<string, object?>();
                        for (int i = 0; i < n; ++i)
                        {
                            var key = Object(UInt(p + i * referenceSize, referenceSize), depth + 1) as string ?? throw new InvalidDataException("Invalid property-list key.");
                            dict.Add(key, Object(UInt(p + (n + i) * referenceSize, referenceSize), depth + 1));
                        }
                        result = dict;
                        break;
                    }
                default:
                    throw new InvalidDataException("Unsupported binary property-list type.");
            }
            active.Remove(id);
            cache[id] = result;
            return result;
        }
    }
}

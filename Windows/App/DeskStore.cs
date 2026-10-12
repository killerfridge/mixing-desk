using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows.Threading;
using MixingDesk.Models;
namespace MixingDesk;

sealed record Device(string Uid, string Name, int Inputs, int Outputs)
{
    public override string ToString() => Name;
}
sealed record AudioApp(string Id, string Name)
{
    public override string ToString() => Name;
}
sealed class DeskStore : IAsyncDisposable
{
    readonly NativeClient native = new(); readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(50) };
    readonly DispatcherTimer apply = new() { Interval = TimeSpan.FromMilliseconds(80) };
    readonly string saved = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mixing Desk", "session.json");
    bool polling, pending, disposed, discovery; int tick, generation; string lastAudio = ""; Task? applyTask;
    public Session Session { get; private set; } = Session.Starter();
    public RoutingHistory History { get; } = new();
    public List<Device> Devices { get; private set; } = [];
    public List<AudioApp> Applications { get; private set; } = [];
    public JsonArray Plugins { get; private set; } = [];
    public JsonObject Status { get; private set; } = new();
    public bool Running
    {
        get; private set;
    }
    public bool Busy
    {
        get; private set;
    }
    public string Message { get; private set; } = "Choose an output and sources, then start audio.";
    public event Action? Changed, MeterChanged, DiscoveryChanged;
    public DeskStore(bool loadSavedSession = true)
    {
        try
        {
            if (loadSavedSession && File.Exists(saved))
                Session = Session.Decode(File.ReadAllText(saved));
        }
        catch (Exception e) { Message = "Saved session could not load: " + e.Message; }
        poll.Tick += async (_, _) => await Poll();
        apply.Tick += async (_, _) => { apply.Stop(); await Apply(); };
    }
    public async Task<bool> Initialize()
    {
        await Refresh();
        try
        {
            await native.Call("update", Session.ForHost());
            lastAudio = Session.ForHost();
        }
        catch (Exception e) { Error(e); return false; }
        poll.Start();
        Changed?.Invoke();
        return true;
    }
    public void Error(Exception e)
    {
        StartupLog.Write("Mixer error", e);
        Message = e.Message;
        Changed?.Invoke();
    }
    public void Info(string message)
    {
        Message = message;
        Changed?.Invoke();
    }
    public void Edit(Action<Session> edit, string? routing = null, bool rebuild = true)
    {
        if (Busy || disposed)
            return;
        try
        {
            var before = Session;
            var next = before.Clone();
            edit(next);
            next.Validate();
            if (routing is not null)
                History.Record(routing, before, next);
            Session = next;
            ++generation;
            Save();
            pending = true;
            apply.Stop();
            apply.Start();
            if (rebuild)
                Changed?.Invoke();
        }
        catch (Exception e) { Error(e); }
    }
    public void Undo(bool redo)
    {
        if (Busy || disposed)
            return;
        try
        {
            Session = redo ? History.Redo(Session) : History.Undo(Session);
            ++generation;
            Save();
            pending = true;
            apply.Start();
            Changed?.Invoke();
        }
        catch (Exception e) { Error(e); }
    }
    Task Apply()
    {
        if (disposed)
            return Task.CompletedTask;
        return applyTask is { IsCompleted: false } ? applyTask : applyTask = ApplyPending();
    }
    async Task ApplyPending()
    {
        try
        {
            while (pending)
            {
                pending = false;
                var value = Session.ForHost();
                if (value != lastAudio)
                {
                    await native.Call("update", value);
                    lastAudio = value;
                }
            }
        }
        catch (Exception e) { Error(e); }
    }
    async Task Poll()
    {
        if (polling || disposed || Busy)
            return;
        polling = true;
        try
        {
            Status = (await native.Call("status"))!.AsObject();
            bool running = Status["running"]!.GetValue<bool>();
            if (running != Running)
            {
                Running = running;
                Changed?.Invoke();
            }
            var error = Status["error"]!.GetValue<string>();
            if (error.Length > 0 && Message != error)
                Info(error);
            MeterChanged?.Invoke();
            if (++tick % 40 == 0)
                await Refresh();
            if (tick % 100 == 0)
            {
                // A failed autosave must not disable audio status or metering.
                try { await CaptureStates(); }
                catch (Exception e) { Error(e); }
            }
        }
        catch (Exception e) { poll.Stop(); Error(e); }
        finally { polling = false; }
    }
    public async Task Refresh()
    {
        if (discovery || disposed)
            return;
        discovery = true;
        try
        {
            var devices = (await native.Call("devices"))!.AsArray().Select(d => new Device(d!["uid"]!.GetValue<string>(), d["name"]!.GetValue<string>(), d["inputChannels"]!.GetValue<int>(), d["outputChannels"]!.GetValue<int>())).ToList();
            var apps = (await native.Call("applications"))!.AsArray().Select(a => new AudioApp(a!["id"]!.GetValue<string>(), a["name"]!.GetValue<string>())).ToList();
            bool changed = !Devices.SequenceEqual(devices) || !Applications.SequenceEqual(apps);
            Devices = devices;
            Applications = apps;
            if (changed)
                DiscoveryChanged?.Invoke();
        }
        catch (Exception e) { Error(e); }
        finally { discovery = false; }
    }
    public async Task Toggle()
    {
        if (Busy)
            return;
        Busy = true;
        Changed?.Invoke();
        try
        {
            await Apply();
            if (Running)
            {
                await native.Call("stop");
                Running = false;
                // Stop first so a plugin/save error cannot leave audio running.
                await CaptureStates();
                Info("Audio stopped.");
            }
            else
            {
                await native.Call("start", Session.ForHost());
                Running = true;
                Info("Mixing at 48 kHz. Direct app capture leaves original playback running.");
            }
        }
        catch (Exception e) { Running = false; Error(e); }
        finally { Busy = false; Changed?.Invoke(); }
    }
    public async Task CaptureStates()
    {
        int epoch = generation;
        var states = await native.Call("pluginStates");
        if (epoch != generation || states is not JsonObject obj || obj.Count == 0)
            return;
        // Capturing plugin state does not acknowledge unrelated pending routing edits.
        Session.CaptureStates(obj);
        Save();
    }
    void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(saved)!);
        var temp = saved + ".tmp";
        File.WriteAllText(temp, Session.Encode());
        if (File.Exists(saved))
            File.Copy(saved, saved + ".bak", true);
        File.Move(temp, saved, true);
    }
    public async Task Load(string path)
    {
        if (Busy || disposed)
            return;
        Busy = true;
        ++generation;
        Changed?.Invoke();
        try
        {
            var next = Session.Decode(await File.ReadAllTextAsync(path));
            apply.Stop();
            await Apply();
            pending = false;
            await native.Call("load", next.ForHost());
            Running = false;
            Session = next;
            ++generation;
            History.Clear();
            lastAudio = Session.ForHost();
            Save();
            Info("Session loaded with audio stopped. Foreign devices and unavailable plugins remain offline.");
        }
        finally { Busy = false; Changed?.Invoke(); }
    }
    public async Task Export(string path)
    {
        await Apply();
        await CaptureStates();
        await File.WriteAllTextAsync(path, Session.Encode());
    }
    public async Task Scan()
    {
        if (Busy)
            return;
        Busy = true;
        Changed?.Invoke();
        try
        {
            Plugins = (await native.Call("scanPlugins"))!.AsArray();
            Info($"Found {Plugins.Count} Windows VST3 effects. Reload any unavailable inserts after scanning.");
        }
        catch (Exception e) { Error(e); }
        finally { Busy = false; Changed?.Invoke(); }
    }
    public Task<JsonNode?> PluginCall(string op, JsonObject args) => native.Call(op, args.ToJsonString());
    public async Task ResetMeter(string id = "", bool bus = false)
    {
        try
        {
            await native.Call("resetMeter", new JsonObject { ["id"] = id, ["bus"] = bus }.ToJsonString());
        }
        catch (Exception e) { Error(e); }
    }
    public string SourceName(SourceBinding source) => source.Kind == "application" ? Applications.FirstOrDefault(x => x.Id == source.BundleID)?.Name ?? (source.BundleID.Length == 0 ? "Choose application" : "Application · offline") : Devices.FirstOrDefault(x => x.Uid == source.DeviceUID)?.Name ?? (source.DeviceUID.Length == 0 ? "Choose input" : "Device · offline");
    public async ValueTask DisposeAsync()
    {
        if (disposed)
            return;
        poll.Stop();
        apply.Stop();
        try
        {
            await Apply();
            await CaptureStates();
            await native.Call("stop");
        }
        catch { }
        disposed = true;
        await native.DisposeAsync();
    }
}

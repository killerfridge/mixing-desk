using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Microsoft.Win32;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow : Window
{
    readonly DeskStore store = new(); readonly DockPanel root = new(); readonly ContentControl content = new();
    readonly TextBlock status = Ui.Text("Starting…", 12, Theme.Muted); readonly TextBlock message = Ui.Text("", 12);
    readonly Button start = new() { Content = "Start Audio" }; readonly ComboBox output = new() { Width = 270, Margin = new Thickness(4), DisplayMemberPath = "Name", SelectedValuePath = "Uid" };
    readonly TabControl tabs = new() { Margin = new Thickness(10, 0, 10, 0) }; readonly Dictionary<string, List<Meter>> meters = [];
    readonly System.Windows.Forms.NotifyIcon tray = new(); bool rebuilding, quitting; int selectedTab;
    public MainWindow()
    {
        Title = "Mixing Desk · Windows beta";
        Width = 1180;
        Height = 780;
        MinWidth = 800;
        MinHeight = 520;
        Background = Theme.Background;
        Foreground = Theme.Text;
        Content = root;
        var menu = new Menu();
        var file = new MenuItem { Header = "_File" };
        file.Items.Add(Item("_Open Session…", async () => await Open()));
        file.Items.Add(Item("_Export Session…", async () => await Export()));
        file.Items.Add(new Separator());
        file.Items.Add(Item("_Quit", async () => await Quit()));
        menu.Items.Add(file);
        var desk = new MenuItem { Header = "_Desk" };
        desk.Items.Add(Item("Add Channel", AddChannel));
        desk.Items.Add(Item("Add Bus", AddBus));
        desk.Items.Add(Item("Clear All Solos", () => store.Edit(s => s.Strips.ForEach(x => x.Solo = false))));
        desk.Items.Add(Item("Reset All Meters", async () => await store.ResetMeter()));
        desk.Items.Add(Item("Scan VST3 Effects", async () => await store.Scan()));
        menu.Items.Add(desk);
        var help = new MenuItem { Header = "_Help" };
        help.Items.Add(Item("Windows Setup Guide", () => { tabs.SelectedIndex = 3; }));
        menu.Items.Add(help);
        DockPanel.SetDock(menu, Dock.Top);
        root.Children.Add(menu);
        var toolbar = new DockPanel { Margin = new Thickness(16, 12, 16, 8) };
        toolbar.Children.Add(Ui.Text("MIXING DESK", 22));
        var actions = Ui.Row(Ui.Text("Monitor", 12, Theme.Muted), output, start);
        DockPanel.SetDock(actions, Dock.Right);
        toolbar.Children.Add(actions);
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);
        output.SelectionChanged += (_, _) => { if (!rebuilding && output.SelectedItem is Device d) store.Edit(s => s.SelectMonitor(d.Uid, d.Outputs), "Change monitor"); };
        start.Click += async (_, _) => await store.Toggle();
        var quick = Ui.Row(Ui.Button("+ Channel", AddChannel), Ui.Button("+ Bus", AddBus), Ui.Button("Undo routing", () => store.Undo(false)), Ui.Button("Redo routing", () => store.Undo(true)), Ui.Button("Clear solos", () => store.Edit(s => s.Strips.ForEach(x => x.Solo = false))), Ui.Button("Reset meters", async () => await store.ResetMeter()));
        quick.Margin = new Thickness(12, 0, 12, 8);
        DockPanel.SetDock(quick, Dock.Top);
        root.Children.Add(quick);
        var footer = new StackPanel { Margin = new Thickness(12, 5, 12, 8) };
        footer.Children.Add(message);
        footer.Children.Add(status);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        foreach (var name in new[] { "Desk", "Patching", "Pipeline", "Setup" })
            tabs.Items.Add(new TabItem { Header = name });
        tabs.SelectionChanged += (_, e) => { if (e.Source == tabs && !rebuilding) { selectedTab = tabs.SelectedIndex; BuildBody(); } };
        DockPanel.SetDock(tabs, Dock.Top);
        root.Children.Add(tabs);
        root.Children.Add(content);
        store.Changed += Rebuild;
        store.MeterChanged += UpdateMeters;
        store.DiscoveryChanged += Rebuild;
        Loaded += async (_, _) => { Show(); await store.Initialize(); };
        Closing += (_, e) => { if (!quitting) { e.Cancel = true; Hide(); } };
        PreviewKeyDown += (_, e) => { if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return; if (e.Key == Key.O) { _ = Open(); e.Handled = true; } if (e.Key == Key.S && (Keyboard.Modifiers & ModifierKeys.Shift) != 0) { _ = Export(); e.Handled = true; } if (e.Key == Key.Z) { store.Undo((Keyboard.Modifiers & ModifierKeys.Shift) != 0); e.Handled = true; } if (e.Key == Key.Y) { store.Undo(true); e.Handled = true; } if (e.Key == Key.L && (Keyboard.Modifiers & ModifierKeys.Shift) != 0) { store.Edit(s => s.Strips.ForEach(x => x.Solo = false)); e.Handled = true; } };
        tray.Icon = System.Drawing.SystemIcons.Application;
        tray.Text = "Mixing Desk";
        tray.Visible = true;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(() => { Show(); Activate(); });
        tray.ContextMenuStrip = new();
        tray.ContextMenuStrip.Items.Add("Show Mixing Desk", null, (_, _) => Dispatcher.Invoke(() => { Show(); Activate(); }));
        tray.ContextMenuStrip.Items.Add("Start / Stop Audio", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await store.Toggle()).Task.Unwrap());
        tray.ContextMenuStrip.Items.Add("Quit", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await Quit()).Task.Unwrap());
        SystemEvents.PowerModeChanged += PowerChanged;
        Rebuild();
    }
    static MenuItem Item(string name, Action action)
    {
        var item = new MenuItem { Header = name };
        item.Click += (_, _) => action();
        return item;
    }
    void PowerChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Suspend)
            Dispatcher.BeginInvoke(async () => { if (store.Running) await store.Toggle(); store.Info("Audio stopped for sleep. Restart audio when ready."); });
    }
    async Task Quit()
    {
        if (quitting)
            return;
        quitting = true;
        SystemEvents.PowerModeChanged -= PowerChanged;
        tray.Visible = false;
        tray.Dispose();
        await store.DisposeAsync();
        Application.Current.Shutdown();
    }
    async Task Open()
    {
        var dialog = new OpenFileDialog { Filter = "Mixing Desk session (*.json)|*.json|All files|*.*" };
        if (dialog.ShowDialog(this) == true)
            try
            {
                await store.Load(dialog.FileName);
            }
            catch (Exception e) { store.Error(e); }
    }
    async Task Export()
    {
        var dialog = new SaveFileDialog { Filter = "Mixing Desk session (*.json)|*.json", FileName = "My Desk.json" };
        if (dialog.ShowDialog(this) == true)
            try
            {
                await store.Export(dialog.FileName);
            }
            catch (Exception e) { store.Error(e); }
    }
    void Rebuild()
    {
        if (rebuilding)
            return;
        rebuilding = true;
        var devices = store.Devices.Where(x => x.Outputs > 0).ToList();
        if (store.Session.MonitorDeviceUID.Length > 0 && devices.All(x => x.Uid != store.Session.MonitorDeviceUID))
            devices.Add(new(store.Session.MonitorDeviceUID, "Selected output · offline", 0, 2));
        output.ItemsSource = devices;
        output.SelectedValue = store.Session.MonitorDeviceUID;
        output.IsEnabled = !store.Busy;
        start.Content = store.Busy ? "Working…" : store.Running ? "Stop Audio" : "Start Audio";
        start.IsEnabled = !store.Busy;
        message.Text = store.Message;
        tabs.SelectedIndex = selectedTab;
        BuildBody();
        rebuilding = false;
        UpdateMeters();
    }
    void BuildBody()
    {
        meters.Clear();
        content.Content = selectedTab switch
        {
            1 => BuildPatching(),
            2 => BuildPipeline(),
            3 => BuildSetup(),
            _ => BuildDesk()
        };
    }
    Meter NewMeter(string id, bool bus)
    {
        var m = new Meter();
        string key = (bus ? "b:" : "s:") + id;
        if (!meters.TryGetValue(key, out var list))
            meters[key] = list = [];
        list.Add(m);
        m.MouseLeftButtonUp += async (_, _) => await store.ResetMeter(id, bus);
        return m;
    }
    void UpdateMeters()
    {
        foreach (var kind in new[] { "strips", "buses" })
        if (store.Status[kind] is JsonArray values)
        foreach (var value in values)
        {
            var key = (kind == "buses" ? "b:" : "s:") + value!["id"]!.GetValue<string>();
            if (meters.TryGetValue(key, out var list))
            foreach (var meter in list)
                meter.Update(value);
        }
        double load = store.Status["load"]?.GetValue<double>() ?? 0;
        int solos = store.Session.Strips.Count(x => x.Solo);
        var offline = store.Status["offline"] as JsonArray;
        var plugins = store.Status["plugins"] as JsonArray;
        int unavailable = plugins?.Count(x => x?["available"]?.GetValue<bool>() == false) ?? 0;
        status.Text = $"{(store.Running ? "RUNNING" : "STOPPED")}  ·  48 kHz  ·  DSP {load:P0}  ·  Solo: {solos}  ·  Protection: {(store.Session.OutputProtectionEnabled ? "on" : "bypassed")} (+2 ms)" + ((offline?.Count ?? 0) > 0 ? $"  ·  {offline!.Count} offline source/output(s)" : "") + (unavailable > 0 ? $"  ·  {unavailable} unavailable plugin(s)" : "");
        if (store.Status["clocks"] is JsonArray clocks)
            status.ToolTip = string.Join("\n", clocks.Select(c => $"{(c!["master"]!.GetValue<bool>() ? "Master" : "Synchronized")}: buffer {c["bufferFrames"]} frames, period {c["periodFrames"]} frames (0 = unavailable), endpoint latency {c["latencyMs"]} ms, underruns {c["underruns"]}, overruns {c["overruns"]}, drift {c["driftPPM"]} ppm"));
    }
    UIElement BuildDesk()
    {
        var root = new StackPanel();
        var strips = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var strip in store.Session.Strips)
            strips.Children.Add(ChannelCard(strip));
        root.Children.Add(Ui.Text("CHANNELS", 12, Theme.Muted));
        root.Children.Add(new ScrollViewer { Content = strips, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        root.Children.Add(Ui.Row(Ui.Text("BUSES", 12, Theme.Muted), Ui.Check("Final output protection", store.Session.OutputProtectionEnabled, value => store.Edit(s => s.OutputProtectionEnabled = value))));
        var buses = new WrapPanel();
        foreach (var bus in store.Session.Buses)
            buses.Children.Add(BusCard(bus));
        root.Children.Add(buses);
        return new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(12) };
    }
    UIElement ChannelCard(ChannelStrip strip)
    {
        string id = strip.Id;
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text(strip.Name, 17));
        panel.Children.Add(Ui.Text(store.SourceName(strip.Source), 11, Theme.Muted));
        panel.Children.Add(Ui.Button("Source / Settings", () => ChannelDialog(id)));
        panel.Children.Add(NewMeter(id, false));
        panel.Children.Add(Ui.Row(Ui.Level("FADER · dB", strip.FaderDB, x => store.Edit(s => s.Strips.Single(y => y.Id == id).FaderDB = x, rebuild: false), vertical: true), Ui.Level("TRIM · dB", strip.TrimDB, x => store.Edit(s => s.Strips.Single(y => y.Id == id).TrimDB = x, rebuild: false), vertical: true)));
        panel.Children.Add(Ui.Level("PAN / BALANCE", strip.Pan, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Pan = x, rebuild: false), -1, 1));
        panel.Children.Add(Ui.Row(Ui.Check("Mute", strip.Muted, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Muted = x)), Ui.Check("Solo", strip.Solo, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Solo = x))));
        panel.Children.Add(Ui.Check("Peak protection", strip.LimiterEnabled, x => store.Edit(s => s.Strips.Single(y => y.Id == id).LimiterEnabled = x)));
        panel.Children.Add(Ui.Row(Ui.Button("Sends", () => SendsDialog(id, false)), Ui.Button("Inserts · " + strip.Inserts.Count, () => InsertsDialog(id, false))));
        return Ui.Card(panel, 200);
    }
    UIElement BusCard(Bus bus)
    {
        string id = bus.Id;
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text(bus.Name, 17));
        panel.Children.Add(Ui.Text(bus.Kind == "call" ? "Call mix · return excluded" : bus.Kind == "monitor" ? "Headphones / monitor" : "Independent mix", 11, Theme.Muted));
        panel.Children.Add(NewMeter(id, true));
        panel.Children.Add(Ui.Level("LEVEL · dB", bus.GainDB, x => store.Edit(s => s.Buses.Single(y => y.Id == id).GainDB = x, rebuild: false)));
        panel.Children.Add(Ui.Check("Mute", bus.Muted, x => store.Edit(s => s.Buses.Single(y => y.Id == id).Muted = x)));
        panel.Children.Add(Ui.Row(Ui.Button("Settings", () => BusDialog(id)), Ui.Button("Sends", () => SendsDialog(id, true))));
        panel.Children.Add(Ui.Row(Ui.Button("Inserts · " + bus.Inserts.Count, () => InsertsDialog(id, true)), Ui.Button("Patch output", () => RouteDialog(null, "bus", id))));
        return Ui.Card(panel, 245);
    }
    void AddChannel()
    {
        if (store.Session.Strips.Count >= 64)
            return;
        var channel = new ChannelStrip { Name = "Channel " + (store.Session.Strips.Count + 1), Sends = store.Session.Buses.Select(b => new Send { BusID = b.Id }).ToList() };
        store.Edit(s => s.Strips.Add(channel), "Add channel");
        ChannelDialog(channel.Id);
    }
    void AddBus()
    {
        if (store.Session.Buses.Count >= 16)
            return;
        var bus = new Bus { Name = "Mix " + (store.Session.Buses.Count + 1) };
        store.Edit(s => s.Buses.Add(bus), "Add bus");
        BusDialog(bus.Id);
    }
    UIElement BuildSetup()
    {
        var p = new StackPanel { MaxWidth = 800, Margin = new Thickness(28) };
        p.Children.Add(Ui.Text("Your Windows desk", 28));
        var buffer = new ComboBox { ItemsSource = new[] { 32, 64, 128, 256, 512, 1024, 2048, 4096 }, SelectedItem = store.Session.BufferFrames, Width = 150, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(4) };
        buffer.SelectionChanged += (_, _) => { if (buffer.SelectedItem is int frames) store.Edit(s => s.BufferFrames = frames); };
        p.Children.Add(Ui.Text("Buffer request (frames; actual device buffering appears in the status tooltip)", 12, Theme.Muted));
        p.Children.Add(buffer);
        p.Children.Add(Ui.Text("1 · Choose headphones and a microphone", 18));
        p.Children.Add(Ui.Text("Select your monitor output at the top. Configure Microphone using Source / Settings. Nothing starts until you choose Start Audio. If the selected monitor disappears, audio stops; the app never switches to speakers."));
        p.Children.Add(Ui.Text("2 · Decide how to capture each application", 18));
        p.Children.Add(Ui.Text("Direct application capture copies an app’s audio and leaves its normal playback running. The starter session therefore disables those channels’ Monitor sends. Turn them on only when the original audio is not already reaching your headphones. If an application restarts, stop and start audio to bind its new process."));
        p.Children.Add(Ui.Text("For full mixer control, install a virtual cable separately and choose it as the app’s playback output in the app or Windows Volume Mixer. Then select the cable’s recording endpoint as a channel input. You can also direct-capture the app while its playback is routed to that otherwise-unmonitored cable. Avoid Windows ‘Listen to this device’, which adds a second monitoring path."));
        p.Children.Add(Ui.Button("Open VB-CABLE website", () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://vb-audio.com/Cable/") { UseShellExecute = true })));
        p.Children.Add(Ui.Text("3 · Send the Call and Stream buses to other apps", 18));
        p.Children.Add(Ui.Text("In Patching, connect Call to a separate cable’s playback endpoint (often called CABLE Input). Select that cable’s recording endpoint (CABLE Output) as the microphone in your call app. Keep Call Return excluded in Call’s settings. Independent call and stream mixes need separate cable pairs. Never send a bus into a cable that feeds that same bus."));
        p.Children.Add(Ui.Text("4 · Add effects and save your desk", 18));
        p.Children.Add(Ui.Text("Scan installed Windows x64 VST3 effects from the Desk menu, then add them under Inserts. Effects use parameter controls. Mac Audio Units and missing effects retain their saved state but remain unavailable; bypass them explicitly to hear the dry signal. Export Session saves portable JSON. Device and application assignments must be rebound on another platform."));
        p.Children.Add(Ui.Text("Windows beta limits", 18));
        p.Children.Add(Ui.Text("Windows 11 x64; Windows 10 22H2 compatibility testing. 48 kHz engine, WASAPI shared audio, mono/stereo effects. No ASIO, custom virtual driver, VST2, MIDI, vendor effect windows, or parallel-path delay compensation. Device synchronisation adds buffering; instrument-monitoring latency is not guaranteed. Active plugins run in the app and can crash or hang it."));
        p.Children.Add(Ui.Text("Closing the window keeps the tray mixer running. Quit from the File menu or tray to stop it. Sessions autosave under %LOCALAPPDATA%\\Mixing Desk. Audio stays local; there are no accounts, telemetry, automatic update checks, or audio-file recording."));
        return new ScrollViewer { Content = p, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
}

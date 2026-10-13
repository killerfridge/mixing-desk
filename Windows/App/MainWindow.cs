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
    readonly DeskStore store; readonly DockPanel root = new(); readonly ContentControl content = new();
    readonly TextBlock status = Ui.Text("Starting…", 12, Theme.Muted); readonly TextBlock message = Ui.Text("", 12);
    readonly Button start = new() { Content = "Start Audio", VerticalAlignment = VerticalAlignment.Center }; readonly ComboBox output = new() { Width = 250, Margin = new Thickness(4), VerticalAlignment = VerticalAlignment.Center, DisplayMemberPath = "Name", SelectedValuePath = "Uid" };
    readonly TabControl tabs = new() { Margin = new Thickness(10, 0, 10, 0) }; readonly Dictionary<string, List<Meter>> meters = [];
    readonly System.Windows.Forms.NotifyIcon tray = new(); bool rebuilding, quitting; int selectedTab;
    readonly TextBlock sessionTitle = Ui.Text("", 11, Theme.Muted);
    readonly Button protection = Ui.Button("Output protection", () => { });
    readonly WrapPanel quick = new();
    public MainWindow(bool smokeTest = false)
    {
        store = new DeskStore(loadSavedSession: !smokeTest);
        Title = "Mixing Desk · Windows beta";
        Width = 1180;
        Height = 780;
        MinWidth = 800;
        MinHeight = 520;
        Theme.Bind(this, BackgroundProperty, Theme.Background);
        Theme.Bind(this, ForegroundProperty, Theme.Text);
        FontFamily = new FontFamily("Segoe UI");
        UseLayoutRounding = true;
        Content = root;
        var menu = new Menu();
        var file = new MenuItem { Header = "_File" };
        file.Items.Add(Item("_Open Session…", async () => await Open()));
        file.Items.Add(Item("_Export Session…", async () => await Export()));
        file.Items.Add(Item("Rename session…", RenameSession));
        file.Items.Add(Item("Save preset…", SavePreset));
        var presets = new MenuItem { Header = "Load preset" };
        presets.SubmenuOpened += (_, _) => { presets.Items.Clear(); foreach (var path in PresetFiles()) presets.Items.Add(Item(System.IO.Path.GetFileNameWithoutExtension(path), async () => { try { await store.Load(path); } catch (Exception e) { store.Error(e); } })); if (presets.Items.Count == 0) presets.Items.Add(new MenuItem { Header = "No saved presets", IsEnabled = false }); };
        file.Items.Add(presets);
        file.Items.Add(new Separator());
        file.Items.Add(Item("_Quit", async () => await Quit()));
        menu.Items.Add(file);
        var desk = new MenuItem { Header = "_Desk" };
        desk.Items.Add(Item("Add Channel", AddChannel));
        desk.Items.Add(Item("Add Bus", AddBus));
        desk.Items.Add(Item("Clear All Solos", () => store.Edit(s => s.Strips.ForEach(x => x.Solo = false))));
        desk.Items.Add(Item("Reset All Meters", async () => await store.ResetMeter()));
        desk.Items.Add(Item("Output Protection…", ShowOutputProtection));
        desk.Items.Add(Item("Scan VST3 Effects", async () => await store.Scan()));
        menu.Items.Add(desk);
        var view = new MenuItem { Header = "_View" };
        var appearance = new MenuItem { Header = "Appearance" };
        foreach (string choice in new[] { "System", "Light", "Dark" })
        {
            var item = Item(choice, () => { Preferences.Current.Appearance = choice; Preferences.Current.Save(); RefreshAppearance(); });
            item.IsCheckable = true;
            appearance.Items.Add(item);
        }
        appearance.SubmenuOpened += (_, _) => { foreach (MenuItem item in appearance.Items) item.IsChecked = (string)item.Header == Preferences.Current.Appearance; };
        view.Items.Add(appearance);
        var density = new MenuItem { Header = "Desk layout" };
        foreach (string choice in new[] { "Automatic", "Compact", "Comfortable" })
        {
            var item = Item(choice, () => { Preferences.Current.Density = choice; Preferences.Current.Save(); Rebuild(); });
            item.IsCheckable = true;
            density.Items.Add(item);
        }
        density.SubmenuOpened += (_, _) => { foreach (MenuItem item in density.Items) item.IsChecked = (string)item.Header == Preferences.Current.Density; };
        view.Items.Add(density);
        menu.Items.Add(view);
        var help = new MenuItem { Header = "_Help" };
        help.Items.Add(Item("Windows Setup Guide", () => { tabs.SelectedIndex = 3; }));
        menu.Items.Add(help);
        DockPanel.SetDock(menu, Dock.Top);
        root.Children.Add(menu);
        var toolbar = new DockPanel { Margin = new Thickness(16, 6, 16, 6) };
        var brand = new StackPanel();
        var brandName = Ui.Text("MIXING DESK", 22);
        brandName.FontWeight = FontWeights.Bold;
        brand.Children.Add(brandName);
        brand.Children.Add(sessionTitle);
        var actions = Ui.Row(Ui.Text("Monitor", 12, Theme.Muted), output, start);
        actions.VerticalAlignment = VerticalAlignment.Center;
        DockPanel.SetDock(actions, Dock.Right);
        toolbar.Children.Add(actions);
        toolbar.Children.Add(brand);
        DockPanel.SetDock(toolbar, Dock.Top);
        root.Children.Add(toolbar);
        output.SelectionChanged += (_, _) => { if (!rebuilding && output.SelectedItem is Device d) store.Edit(s => s.SelectMonitor(d.Uid, d.Outputs), "Change monitor"); };
        start.Click += async (_, _) => await store.Toggle();
        foreach (var button in new[] { Ui.Button("+ Channel", AddChannel), Ui.Button("+ Bus", AddBus), Ui.Button("Undo", () => store.Undo(false)), Ui.Button("Redo", () => store.Undo(true)), Ui.Button("Clear solos", () => store.Edit(s => s.Strips.ForEach(x => x.Solo = false))), Ui.Button("Reset meters", async () => await store.ResetMeter()), protection })
            quick.Children.Add(button);
        protection.Click += (_, _) => ShowOutputProtection();
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
        var firstRender = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ContentRendered += (_, _) => { StartupLog.Write("Main window rendered"); firstRender.TrySetResult(); };
        Loaded += async (_, _) =>
        {
            StartupLog.Write("Main window loaded; initializing session");
            bool initialized = await store.Initialize();
            StartupLog.Write(initialized ? "Session initialized" : "Session initialization failed");
            if (smokeTest)
            {
                await firstRender.Task;
                if (initialized)
                    await CheckInterface();
                StartupLog.Write(initialized ? "PASS: desktop startup" : "FAIL: desktop startup");
                await Quit(initialized ? 0 : 1);
            }
        };
        Closing += (_, e) => { if (!quitting) { e.Cancel = true; Hide(); } };
        PreviewKeyDown += (_, e) => { if (e.OriginalSource is TextBox) return; if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return; if (e.Key == Key.O) { _ = Open(); e.Handled = true; } if (e.Key == Key.S && (Keyboard.Modifiers & ModifierKeys.Shift) != 0) { _ = Export(); e.Handled = true; } if (e.Key == Key.Z) { store.Undo((Keyboard.Modifiers & ModifierKeys.Shift) != 0); e.Handled = true; } if (e.Key == Key.Y) { store.Undo(true); e.Handled = true; } if (e.Key == Key.L && (Keyboard.Modifiers & ModifierKeys.Shift) != 0) { store.Edit(s => s.Strips.ForEach(x => x.Solo = false)); e.Handled = true; } };
        tray.Icon = System.Drawing.SystemIcons.Application;
        tray.Text = "Mixing Desk";
        tray.Visible = true;
        tray.DoubleClick += (_, _) => Dispatcher.Invoke(() => { Show(); Activate(); });
        tray.ContextMenuStrip = new();
        tray.ContextMenuStrip.Items.Add("Show Mixing Desk", null, (_, _) => Dispatcher.Invoke(() => { Show(); Activate(); }));
        tray.ContextMenuStrip.Items.Add("Start / Stop Audio", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await store.Toggle()).Task.Unwrap());
        tray.ContextMenuStrip.Items.Add("Clear All Solos", null, (_, _) => Dispatcher.Invoke(() => store.Edit(s => s.Strips.ForEach(x => x.Solo = false))));
        tray.ContextMenuStrip.Items.Add("Reset All Meters", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await store.ResetMeter()).Task.Unwrap());
        tray.ContextMenuStrip.Items.Add("Quit", null, async (_, _) => await Dispatcher.InvokeAsync(async () => await Quit()).Task.Unwrap());
        SystemEvents.PowerModeChanged += PowerChanged;
        SystemEvents.UserPreferenceChanged += AppearanceChanged;
        bool compact = CompactDesk;
        SizeChanged += (_, _) => { bool next = CompactDesk; if (next != compact) { compact = next; if (selectedTab == 0) Rebuild(); } };
        PreviewKeyDown += (_, e) => { if (selectedTab == 2 && e.OriginalSource is not TextBox) pipelineKeys?.Invoke(e); };
        Rebuild();
    }
    bool CompactDesk => Preferences.Current.Density == "Compact" || (Preferences.Current.Density == "Automatic" && (ActualWidth < 1250 || ActualHeight < 850));
    void RefreshAppearance()
    {
        Theme.Apply();
        Rebuild();
    }
    void AppearanceChanged(object sender, UserPreferenceChangedEventArgs e)
    {
        if (Preferences.Current.Appearance == "System")
            Dispatcher.BeginInvoke(RefreshAppearance);
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
    async Task Quit(int exitCode = 0)
    {
        if (quitting)
            return;
        quitting = true;
        SystemEvents.PowerModeChanged -= PowerChanged;
        SystemEvents.UserPreferenceChanged -= AppearanceChanged;
        tray.Visible = false;
        tray.Dispose();
        await store.DisposeAsync();
        Application.Current.Shutdown(exitCode);
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
        sessionTitle.Text = $"{store.Session.Name}  /  {store.Session.Strips.Count} channels · {store.Session.Buses.Count} buses";
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
        quick.Visibility = selectedTab == 2 ? Visibility.Collapsed : Visibility.Visible;
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
        m.Reset = async () => await store.ResetMeter(id, bus);
        System.Windows.Automation.AutomationProperties.SetName(m, "Reset " + (bus ? "bus" : "channel") + " peak meter");
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
        var outputMeters = store.Status["outputs"] as JsonArray;
        double reduction = outputMeters?.Select(x => x?["reductionDB"]?.GetValue<double>() ?? 0).DefaultIfEmpty(0).Max() ?? 0;
        bool outputClip = outputMeters?.Any(x => x?["clip"]?.GetValue<bool>() == true) == true;
        protection.Content = (outputClip ? "OVER · " : "") + (!store.Session.OutputProtectionEnabled ? "Output protection bypassed" : reduction > .05 ? $"OUTPUT LIMIT −{reduction:0.0} dB" : "Output protection");
        protection.Foreground = outputClip ? Brushes.OrangeRed : reduction > .05 ? Theme.Accent : Theme.Muted;
        if (store.Status["clocks"] is JsonArray clocks)
            status.ToolTip = string.Join("\n", clocks.Select(c => $"{(c!["master"]!.GetValue<bool>() ? "Master" : "Synchronized")}: buffer {c["bufferFrames"]} frames, period {c["periodFrames"]} frames (0 = unavailable), endpoint latency {c["latencyMs"]} ms, underruns {c["underruns"]}, overruns {c["overruns"]}, drift {c["driftPPM"]} ppm"));
    }
    UIElement BuildDesk()
    {
        var root = new StackPanel();
        var bank = new ComboBox { ItemsSource = new[] { "All", "Channels", "Buses" }, SelectedItem = Preferences.Current.Bank, Width = 120, Margin = new Thickness(4) };
        bank.SelectionChanged += (_, _) => { if (bank.SelectedItem is string value) { Preferences.Current.Bank = value; Preferences.Current.Save(); Rebuild(); } };
        root.Children.Add(Ui.Row(Ui.Text("Your desk", 23), bank, Ui.Text(CompactDesk ? "Compact layout" : "Comfortable layout", 12, Theme.Muted)));
        var strips = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var strip in store.Session.Strips)
            strips.Children.Add(ChannelCard(strip));
        if (Preferences.Current.Bank != "Buses")
        {
            root.Children.Add(Ui.Text("CHANNELS", 12, Theme.Muted));
            root.Children.Add(new ScrollViewer { Content = strips, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        }
        root.Children.Add(Ui.Row(Ui.Text("BUSES", 12, Theme.Muted), Ui.Check("Final output protection", store.Session.OutputProtectionEnabled, value => store.Edit(s => s.OutputProtectionEnabled = value))));
        var buses = new WrapPanel();
        foreach (var bus in store.Session.Buses)
            buses.Children.Add(BusCard(bus));
        if (Preferences.Current.Bank != "Channels")
            root.Children.Add(buses);
        return new ScrollViewer { Content = root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Margin = new Thickness(12) };
    }
    UIElement ChannelCard(ChannelStrip strip)
    {
        string id = strip.Id;
        var panel = new StackPanel();
        panel.Children.Add(Ui.Text("CHANNEL", 9, Theme.Color(strip.Color)));
        panel.Children.Add(Ui.Text(strip.Name, 17));
        var source = Ui.Button("", () => ChannelDialog(id));
        source.Content = new TextBlock { Text = store.SourceName(strip.Source), TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 11 };
        source.ToolTip = store.SourceName(strip.Source) + " · Source / Settings";
        System.Windows.Automation.AutomationProperties.SetName(source, strip.Name + " source and settings");
        panel.Children.Add(source);
        panel.Children.Add(Ui.CompactLevel("TRIM · dB", strip.TrimDB, x => store.Edit(s => s.Strips.Single(y => y.Id == id).TrimDB = x, rebuild: false), -24, 24, compact: CompactDesk));
        panel.Children.Add(Ui.Row(Ui.Toggle("M", strip.Muted, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Muted = x, rebuild: false), "Mute"), Ui.Toggle("S", strip.Solo, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Solo = x, rebuild: false), "Solo in monitor"), Ui.Toggle("Ø", strip.Polarity, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Polarity = x, rebuild: false), "Invert polarity")));
        double faderHeight = CompactDesk ? 110 : 180;
        var meter = NewMeter(id, false);
        meter.Vertical = true;
        meter.Width = 76;
        meter.Height = faderHeight + 23;
        meter.Margin = new Thickness(8, 29, 0, 0);
        var fader = Ui.Level("FADER · dB", strip.FaderDB, x => store.Edit(s => s.Strips.Single(y => y.Id == id).FaderDB = x, rebuild: false), vertical: true, verticalHeight: faderHeight);
        panel.Children.Add(Ui.Row(fader, meter));
        panel.Children.Add(Ui.CompactLevel("PAN / BALANCE", strip.Pan, x => store.Edit(s => s.Strips.Single(y => y.Id == id).Pan = x, rebuild: false), -1, 1, compact: CompactDesk));
        panel.Children.Add(Ui.Check("Peak protection", strip.LimiterEnabled, x => store.Edit(s => s.Strips.Single(y => y.Id == id).LimiterEnabled = x)));
        panel.Children.Add(Ui.Row(Ui.Button("Sends", () => SendsDialog(id, false)), Ui.Button("Inserts · " + strip.Inserts.Count, () => InsertsDialog(id, false))));
        var sends = new StackPanel();
        foreach (var send in strip.Sends)
        {
            string target = send.BusID;
            sends.Children.Add(Ui.CompactLevel(store.Session.Buses.Single(b => b.Id == target).Name.ToUpperInvariant(), send.GainDB, x => store.Edit(s => s.Strips.Single(c => c.Id == id).Sends.Single(v => v.BusID == target).GainDB = x, "Send level", false), -90, 12, active => store.RoutingGesture(active, "Send level")));
            sends.Children.Add(Ui.Toggle("PRE", send.PreFader, x => store.Edit(s => s.Strips.Single(c => c.Id == id).Sends.Single(v => v.BusID == target).PreFader = x, "Send pre/post", false), "Pre-fader send"));
        }
        var expander = new Expander { Header = "SENDS", Content = sends, IsExpanded = !CompactDesk, Foreground = Theme.Muted, Margin = new Thickness(4) };
        panel.Children.Add(expander);
        var reorder = Ui.Row(Ui.Button("←", () => MoveStrip(id, -1)), Ui.Button("→", () => MoveStrip(id, 1)));
        panel.Children.Add(reorder);
        var card = Ui.Card(panel, CompactDesk ? 210 : 235);
        card.BorderBrush = Theme.Color(strip.Color);
        return card;
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

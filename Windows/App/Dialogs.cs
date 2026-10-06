using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow
{
    Window Dialog(string title, StackPanel panel, Action? commit = null, string ok = "Save")
    {
        var window = new Window { Title = title, Owner = this, Width = 620, MaxHeight = Math.Max(400, SystemParameters.WorkArea.Height - 80), SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Theme.Background, Foreground = Theme.Text };
        var dock = new DockPanel { Margin = new Thickness(16) };
        var buttons = Ui.Row(Ui.Button(commit is null ? "Close" : "Cancel", () => window.Close()));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        if (commit is not null)
            buttons.Children.Add(Ui.Button(ok, () => { try { commit(); window.Close(); } catch (Exception e) { MessageBox.Show(window, e.Message, title, MessageBoxButton.OK, MessageBoxImage.Error); } }));
        DockPanel.SetDock(buttons, Dock.Bottom);
        dock.Children.Add(buttons);
        dock.Children.Add(new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = window.MaxHeight - 110 });
        window.Content = dock;
        return window;
    }
    static TextBox Field(StackPanel panel, string label, string value)
    {
        panel.Children.Add(Ui.Text(label, 12, Theme.Muted));
        var box = new TextBox { Text = value };
        panel.Children.Add(box);
        return box;
    }
    static int[] ParseChannels(string text)
    {
        var channels = text.Split(',').Select(x => int.Parse(x.Trim(), CultureInfo.InvariantCulture) - 1).ToArray();
        Session.Require(channels.Length is 1 or 2 && channels.All(x => x >= 0 && x < 512) && channels.Distinct().Count() == channels.Length, "Enter one channel or two different channels, e.g. 1 or 1,2.");
        return channels;
    }
    static string ChannelText(int[] values) => string.Join(",", values.Select(x => x + 1));
    void CommitEdit(Action<Session> edit, string name)
    {
        var candidate = store.Session.Clone();
        edit(candidate);
        candidate.Validate();
        store.Edit(edit, name);
    }
    void ChannelDialog(string id)
    {
        var strip = store.Session.Strips.Single(x => x.Id == id);
        var p = new StackPanel();
        var name = Field(p, "Channel name", strip.Name);
        p.Children.Add(Ui.Text("Source type", 12, Theme.Muted));
        var kind = new ComboBox { ItemsSource = new[] { "device", "application" }, SelectedItem = strip.Source.Kind, Margin = new Thickness(4) };
        p.Children.Add(kind);
        var choose = new ComboBox { Margin = new Thickness(4), DisplayMemberPath = "Name", SelectedValuePath = "Id" };
        p.Children.Add(choose);
        void Choices()
        {
            var choices = new List<Choice> { new("", "Unassigned") };
            if ((string?)kind.SelectedItem == "application")
                choices.AddRange(store.Applications.Select(x => new Choice(x.Id, x.Name)));
            else
                choices.AddRange(store.Devices.Where(x => x.Inputs > 0).Select(x => new Choice(x.Uid, x.Name)));
            string existing = (string?)kind.SelectedItem == "application" ? strip.Source.BundleID : strip.Source.DeviceUID;
            if (existing.Length > 0 && choices.All(x => x.Id != existing))
                choices.Add(new(existing, "Saved assignment · offline"));
            choose.ItemsSource = choices;
            choose.SelectedValue = existing;
        }
        kind.SelectionChanged += (_, _) => Choices();
        Choices();
        var channels = Field(p, "Input channels (1-based, e.g. 1 or 1,2)", ChannelText(strip.Source.Channels));
        p.Children.Add(Ui.Text("Application associated with a virtual return (optional)", 12, Theme.Muted));
        var returns = new ComboBox { DisplayMemberPath = "Name", SelectedValuePath = "Id", Margin = new Thickness(4) };
        var returnChoices = new List<Choice> { new("", "None") };
        returnChoices.AddRange(store.Applications.Select(x => new Choice(x.Id, x.Name)));
        if (strip.Source.ReturnBundleID.Length > 0 && returnChoices.All(x => x.Id != strip.Source.ReturnBundleID))
            returnChoices.Add(new(strip.Source.ReturnBundleID, "Saved application · offline"));
        returns.ItemsSource = returnChoices;
        returns.SelectedValue = strip.Source.ReturnBundleID;
        p.Children.Add(returns);
        var polarity = Ui.Check("Invert polarity", strip.Polarity, _ => { });
        p.Children.Add(polarity);
        var guitar = Ui.Check("Guitar (for direct-monitoring mode)", strip.Role == "guitar", _ => { });
        p.Children.Add(guitar);
        p.Children.Add(Ui.Text("Direct app capture leaves original playback running. Assigning a new application disables this channel’s Monitor send initially.", 12, Theme.Muted));
        var window = Dialog("Channel Settings", p, () =>
        {
            var selected = (string?)choose.SelectedValue ?? "";
            var type = (string?)kind.SelectedItem ?? "device";
            var mapping = ParseChannels(channels.Text);
            int available = type == "application" ? 2 : store.Devices.FirstOrDefault(x => x.Uid == selected)?.Inputs ?? 512;
            Session.Require(mapping.All(x => x < available), "Choose channels available on this source.");
            CommitEdit(s => { var c = s.Strips.Single(x => x.Id == id); bool newApp = type == "application" && (c.Source.Kind != type || c.Source.BundleID != selected); c.Name = name.Text; c.Polarity = polarity.IsChecked == true; if (guitar.IsChecked == true) c.Role = "guitar"; else if (c.Role == "guitar") c.Role = "generic"; c.Source = new() { Kind = type, DeviceUID = type == "device" ? selected : "", BundleID = type == "application" ? selected : "", Channels = mapping, ReturnBundleID = type == "device" ? (string?)returns.SelectedValue ?? "" : "" }; if (newApp) foreach (var send in c.Sends.Where(x => s.Buses.Any(b => b.Id == x.BusID && b.Kind == "monitor"))) send.GainDB = -90; }, "Configure channel");
        });
        p.Children.Add(Ui.Button("Remove channel", () => { CommitEdit(s => s.RemoveStrip(id), "Remove channel"); window.Close(); }));
        window.ShowDialog();
    }
    sealed record Choice(string Id, string Name)
    {
        public override string ToString() => Name;
    }
    void BusDialog(string id)
    {
        var bus = store.Session.Buses.Single(x => x.Id == id);
        var p = new StackPanel();
        var name = Field(p, "Bus name", bus.Name);
        var exclude = new ComboBox { DisplayMemberPath = "Name", SelectedValuePath = "Id", Margin = new Thickness(4) };
        var choices = new List<Choice> { new("", "No exclusion") };
        choices.AddRange(store.Session.Strips.Select(x => new Choice(x.Id, x.Name)));
        exclude.ItemsSource = choices;
        exclude.SelectedValue = bus.ExcludedStripID;
        p.Children.Add(Ui.Text("Exclude this source and its copies (mix-minus)"));
        p.Children.Add(exclude);
        var direct = Ui.Check("Use hardware direct monitoring for guitar channels", store.Session.MonitoringMode == "directGuitar", _ => { });
        if (bus.Kind == "monitor")
            p.Children.Add(direct);
        var window = Dialog("Bus Settings", p, () => CommitEdit(s => { var b = s.Buses.Single(x => x.Id == id); b.Name = name.Text; b.ExcludedStripID = (string?)exclude.SelectedValue ?? ""; if (b.Kind == "monitor") s.MonitoringMode = direct.IsChecked == true ? "directGuitar" : "mixer"; }, "Configure bus"));
        if (bus.Kind != "monitor")
            p.Children.Add(Ui.Button("Remove bus", () => { CommitEdit(s => s.RemoveBus(id), "Remove bus"); window.Close(); }));
        window.ShowDialog();
    }
    void SendsDialog(string id, bool bus)
    {
        var p = new StackPanel();
        var sends = bus ? store.Session.Buses.Single(x => x.Id == id).Sends : store.Session.Strips.Single(x => x.Id == id).Sends;
        var fields = new List<(string Id, CheckBox Enabled, TextBox Gain, CheckBox Pre)>();
        foreach (var target in store.Session.Buses.Where(x => !bus || x.Id != id))
        {
            var send = sends.FirstOrDefault(x => x.BusID == target.Id);
            var enabled = Ui.Check(target.Name, send is not null, _ => { });
            var gain = new TextBox { Text = (send?.GainDB ?? 0).ToString(CultureInfo.InvariantCulture), Width = 80 };
            var pre = Ui.Check("Pre-fader", send?.PreFader ?? false, _ => { });
            pre.IsEnabled = !bus;
            p.Children.Add(Ui.Row(enabled, gain, Ui.Text("dB"), pre));
            fields.Add((target.Id, enabled, gain, pre));
        }
        Dialog("Sends", p, () => { var values = fields.Where(x => x.Enabled.IsChecked == true).Select(x => new Send { BusID = x.Id, GainDB = double.Parse(x.Gain.Text, CultureInfo.InvariantCulture), PreFader = !bus && x.Pre.IsChecked == true }).ToList(); CommitEdit(s => { if (bus) s.Buses.Single(x => x.Id == id).Sends = values; else s.Strips.Single(x => x.Id == id).Sends = values; }, "Edit sends"); }).ShowDialog();
    }
    UIElement BuildPatching()
    {
        var p = new StackPanel { Margin = new Thickness(22) };
        p.Children.Add(Ui.Text("Output patching", 25));
        p.Children.Add(Ui.Text("Patch a bus or direct channel output to a hardware or virtual-cable playback endpoint. Virtual device creation is supplied by your installed cable driver.", 13, Theme.Muted));
        p.Children.Add(Ui.Button("+ Output route", () => RouteDialog(null)));
        foreach (var route in store.Session.Routes)
        {
            var name = route.SourceKind == "bus" ? store.Session.Buses.FirstOrDefault(x => x.Id == route.SourceID)?.Name : store.Session.Strips.FirstOrDefault(x => x.Id == route.SourceID)?.Name;
            var device = store.Devices.FirstOrDefault(x => x.Uid == route.DestinationUID)?.Name ?? route.DestinationUID + " · offline";
            var row = Ui.Row(Ui.Text($"{name} → {device}  ·  Ch {ChannelText(route.Channels)}  ·  {route.GainDB:0.0} dB"), Ui.Button("Edit", () => RouteDialog(route.Id)), Ui.Button("Remove", () => store.Edit(s => s.Routes.RemoveAll(x => x.Id == route.Id), "Remove output route")));
            p.Children.Add(Ui.Card(row));
        }
        p.Children.Add(Ui.Text("Channel and bus sends", 22));
        foreach (var strip in store.Session.Strips)
            p.Children.Add(Ui.Row(Ui.Text(strip.Name), Ui.Button("Edit sends", () => SendsDialog(strip.Id, false))));
        foreach (var bus in store.Session.Buses)
            p.Children.Add(Ui.Row(Ui.Text(bus.Name), Ui.Button("Edit sends", () => SendsDialog(bus.Id, true))));
        return new ScrollViewer { Content = p, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
    }
    void RouteDialog(string? routeId, string? sourceKind = null, string? sourceId = null, string? destination = null)
    {
        var old = store.Session.Routes.FirstOrDefault(x => x.Id == routeId);
        var p = new StackPanel();
        var source = new ComboBox { Margin = new Thickness(4), DisplayMemberPath = "Name", SelectedValuePath = "Id" };
        source.ItemsSource = store.Session.Buses.Select(x => new Choice("bus:" + x.Id, x.Name + " (bus)")).Concat(store.Session.Strips.Select(x => new Choice("strip:" + x.Id, x.Name + " (channel)"))).ToList();
        source.SelectedValue = (old?.SourceKind ?? sourceKind ?? "bus") + ":" + (old?.SourceID ?? sourceId ?? store.Session.Buses[0].Id);
        p.Children.Add(Ui.Text("Source"));
        p.Children.Add(source);
        var output = new ComboBox { Margin = new Thickness(4), DisplayMemberPath = "Name", SelectedValuePath = "Id" };
        var choices = store.Devices.Where(x => x.Outputs > 0).Select(x => new Choice(x.Uid, x.Name)).ToList();
        string initial = old?.DestinationUID ?? destination ?? store.Session.MonitorDeviceUID;
        if (initial.Length > 0 && choices.All(x => x.Id != initial))
            choices.Add(new(initial, "Saved output · offline"));
        output.ItemsSource = choices;
        output.SelectedValue = initial;
        p.Children.Add(Ui.Text("Playback endpoint"));
        p.Children.Add(output);
        var channels = Field(p, "Output channels (1-based)", ChannelText(old?.Channels ?? [0, 1]));
        var gain = Field(p, "Route gain (dB)", (old?.GainDB ?? 0).ToString(CultureInfo.InvariantCulture));
        var pre = Ui.Check("Pre-fader (direct channels only)", old?.PreFader ?? false, _ => { });
        p.Children.Add(pre);
        Dialog("Output Route", p, () => { var key = ((string?)source.SelectedValue ?? "").Split(':', 2); Session.Require(key.Length == 2, "Choose a source."); string uid = (string?)output.SelectedValue ?? ""; Session.Require(uid.Length > 0, "Choose an output."); var mapping = ParseChannels(channels.Text); var device = store.Devices.FirstOrDefault(x => x.Uid == uid); Session.Require(device is null ? old is not null && old.DestinationUID == uid && old.Channels.SequenceEqual(mapping) : mapping.All(x => x < device.Outputs), "Choose available output channels."); var route = new OutputRoute { Id = old?.Id ?? Session.NewId(), SourceKind = key[0], SourceID = key[1], DestinationUID = uid, Channels = mapping, GainDB = double.Parse(gain.Text, CultureInfo.InvariantCulture), PreFader = key[0] == "strip" && pre.IsChecked == true }; CommitEdit(s => { int i = s.Routes.FindIndex(x => x.Id == route.Id); if (i >= 0) s.Routes[i] = route; else s.Routes.Add(route); }, "Patch output"); }).ShowDialog();
    }
    void InsertsDialog(string id, bool bus)
    {
        var p = new StackPanel();
        var window = Dialog("Inserts", p);
        List<InsertSlot> Slots(Session s) => bus ? s.Buses.Single(x => x.Id == id).Inserts : s.Strips.Single(x => x.Id == id).Inserts;
        void Edit(Action<List<InsertSlot>> action)
        {
            store.Edit(s => action(Slots(s)));
            Refresh();
        }
        void Refresh()
        {
            p.Children.Clear();
            var slots = Slots(store.Session);
            p.Children.Add(Ui.Text("Four ordered inserts · mono/stereo · 48 kHz", 13, Theme.Muted));
            foreach (var slot in slots.ToArray())
            {
                string insertId = slot.Id;
                int index = slots.IndexOf(slot);
                var card = new StackPanel();
                card.Children.Add(Ui.Text($"{index + 1} · {slot.DisplayName}", 16));
                var state = (store.Status["plugins"] as JsonArray)?.FirstOrDefault(x => x?["id"]?.GetValue<string>() == insertId);
                if (state is not null)
                    card.Children.Add(Ui.Text(state["error"]?.GetValue<string>() is string error && error.Length > 0 ? error : $"Latency: {state["latencyFrames"]} samples", 12, Theme.Muted));
                card.Children.Add(Ui.Row(Ui.Check("Bypass", slot.Bypassed, value => Edit(x => x.Single(y => y.Id == insertId).Bypassed = value)), Ui.Button("Edit", async () => { if (slot.Format == "builtin") EqDialog(insertId); else await ParameterDialog(insertId); }), Ui.Button("↑", () => Edit(x => { int n = x.FindIndex(y => y.Id == insertId); if (n > 0) (x[n - 1], x[n]) = (x[n], x[n - 1]); })), Ui.Button("↓", () => Edit(x => { int n = x.FindIndex(y => y.Id == insertId); if (n < x.Count - 1) (x[n + 1], x[n]) = (x[n], x[n + 1]); })), Ui.Button("Remove", () => Edit(x => x.RemoveAll(y => y.Id == insertId)))));
                if (slot.Format != "builtin")
                    card.Children.Add(Ui.Button("Reload", async () => { try { await store.PluginCall("reloadPlugin", new() { ["id"] = insertId }); Refresh(); } catch (Exception e) { store.Error(e); } }));
                p.Children.Add(Ui.Card(card));
            }
            if (slots.Count < 4)
            {
                p.Children.Add(Ui.Button("+ Desk EQ", () => Edit(x => x.Add(new()))));
                var plugins = new ComboBox { ItemsSource = store.Plugins.Select(x => new Choice(x!["id"]!.GetValue<string>(), x["name"]!.GetValue<string>())).ToList(), Margin = new Thickness(4) };
                p.Children.Add(plugins);
                p.Children.Add(Ui.Row(Ui.Button("Scan VST3 effects", async () => { await store.Scan(); Refresh(); }), Ui.Button("+ Selected VST3", () => { if (plugins.SelectedItem is Choice c) Edit(x => x.Add(new() { Format = "vst3", Identifier = c.Id, Name = c.Name })); })));
            }
        }
        Refresh();
        window.ShowDialog();
    }
    void EqDialog(string id)
    {
        var slot = store.Session.AllInserts.Single(x => x.Id == id);
        var eq = slot.ReadEq();
        var p = new StackPanel();
        foreach (var spec in new[] { ("LowFrequency", "Low shelf frequency · Hz", 20d, 20000d), ("LowGain", "Low gain · dB", -18d, 18d), ("MidFrequency", "Mid frequency · Hz", 20d, 20000d), ("MidGain", "Mid gain · dB", -18d, 18d), ("MidQ", "Mid Q", .1, 10d), ("HighFrequency", "High shelf frequency · Hz", 20d, 20000d), ("HighGain", "High gain · dB", -18d, 18d), ("OutputGain", "Output gain · dB", -18d, 18d) })
        {
            var property = typeof(EqSettings).GetProperty(spec.Item1)!;
            p.Children.Add(Ui.Level(spec.Item2, (double)property.GetValue(eq)!, value => { property.SetValue(eq, value); store.Edit(s => s.AllInserts.Single(x => x.Id == id).WriteEq(eq), rebuild: false); }, spec.Item3, spec.Item4));
        }
        Dialog("Desk EQ", p).ShowDialog();
    }
    async System.Threading.Tasks.Task ParameterDialog(string id)
    {
        try
        {
            var parameters = (await store.PluginCall("pluginParameters", new()
            {
                ["id"] = id
            }))!.AsArray();
            var p = new StackPanel();
            if (parameters.Count == 0)
                p.Children.Add(Ui.Text("No parameters are available. Check the insert’s status, scan plugins, or reload it."));
            foreach (var parameter in parameters)
            {
                uint param = parameter!["id"]!.GetValue<uint>();
                var control = Ui.Level(parameter["name"]!.GetValue<string>() + " · normalized", parameter["value"]!.GetValue<double>(), async value => { try { await store.PluginCall("setParameter", new() { ["id"] = id, ["parameter"] = param, ["value"] = value }); } catch (Exception e) { store.Error(e); } }, 0, 1);
                control.IsEnabled = !parameter["readOnly"]!.GetValue<bool>();
                p.Children.Add(control);
            }
            Dialog("VST3 Parameters", p).ShowDialog();
            await store.CaptureStates();
        }
        catch (Exception e) { store.Error(e); }
    }
}

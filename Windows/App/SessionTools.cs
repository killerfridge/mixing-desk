using System;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow
{
    static string PresetDirectory => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mixing Desk", "Presets");
    static string[] PresetFiles()
    {
        try
        {
            return Directory.Exists(PresetDirectory) ? Directory.GetFiles(PresetDirectory, "*.json").OrderBy(Path.GetFileNameWithoutExtension).ToArray() : [];
        }
        catch { return []; }
    }
    void RenameSession()
    {
        var p = new StackPanel();
        var field = Field(p, "Session name", store.Session.Name);
        Dialog("Rename Session", p, () => { Session.Require(!string.IsNullOrWhiteSpace(field.Text), "Enter a name."); store.Edit(s => s.Name = field.Text.Trim(), audio: false); }).ShowDialog();
    }
    void SavePreset()
    {
        var p = new StackPanel();
        var name = Field(p, "Preset name", store.Session.Name);
        p.Children.Add(Ui.Text("Presets include routing, effects and pipeline positions. Loading one stops audio.", 12, Theme.Muted));
        var window = Dialog("Save Preset", p);
        var save = Ui.Button("Save preset", async () =>
        {
            try
            {
                string title = name.Text.Trim();
                Session.Require(title.Length > 0 && title.Length <= 100 && title.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 && !title.EndsWith('.') && title is not "." and not "..", "Use a valid preset name without file-path characters.");
                Directory.CreateDirectory(PresetDirectory);
                string path = Path.Combine(PresetDirectory, title + ".json");
                if (File.Exists(path) && MessageBox.Show(window, "Replace the existing preset?", title, MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
                    return;
                await store.Export(path);
                store.Info("Saved preset: " + title);
                window.Close();
            }
            catch (Exception e) { MessageBox.Show(window, e.Message, "Save Preset", MessageBoxButton.OK, MessageBoxImage.Error); }
        });
        p.Children.Add(save);
        window.ShowDialog();
    }
    void MoveStrip(string id, int offset)
    {
        store.Edit(s => { int index = s.Strips.FindIndex(x => x.Id == id); int next = index + offset; if (index >= 0 && next >= 0 && next < s.Strips.Count) (s.Strips[index], s.Strips[next]) = (s.Strips[next], s.Strips[index]); }, "Move channel");
    }
    void ShowOutputProtection()
    {
        var p = new StackPanel();
        p.Children.Add(Ui.Text("Final output protection", 24));
        p.Children.Add(Ui.Text("−1 dBFS sample peaks · 48 samples lookahead · 100 ms release", 12, Theme.Muted));
        p.Children.Add(Ui.Check("Enabled", store.Session.OutputProtectionEnabled, x => store.Edit(s => s.OutputProtectionEnabled = x)));
        var readings = new StackPanel();
        p.Children.Add(readings);
        void Refresh()
        {
            readings.Children.Clear();
            var values = store.Status["outputs"] as JsonArray;
            if (values is null || values.Count == 0)
                readings.Children.Add(Ui.Text("No active output destinations.", 13, Theme.Muted));
            else
            foreach (var value in values)
            {
                string names = value?["destinations"] is JsonArray destinations ? string.Join(" / ", destinations.Select(d => (store.Devices.FirstOrDefault(x => x.Uid == d?["uid"]?.GetValue<string>())?.Name ?? "Saved output") + " · Ch " + string.Join(",", d!["channels"]!.AsArray().Select(c => c!.GetValue<int>() + 1)))) : "Output group " + value?["id"];
                double reduction = value?["reductionDB"]?.GetValue<double>() ?? 0;
                bool clip = value?["clip"]?.GetValue<bool>() ?? false;
                readings.Children.Add(Ui.Text(names + "  ·  " + (clip ? "OVER" : reduction > .05 ? $"LIMIT −{reduction:0.0} dB" : "Ready"), 12, clip ? Brushes.OrangeRed : Theme.Text));
            }
        }
        p.Children.Add(Ui.Text("Bus meters precede final output summing and protection. Existing input or plugin distortion and intersample true peaks are not repaired.", 12, Theme.Muted));
        p.Children.Add(Ui.Button("Reset all meters", async () => await store.ResetMeter()));
        var dialog = Dialog("Output Protection", p);
        store.MeterChanged += Refresh;
        dialog.Closed += (_, _) => store.MeterChanged -= Refresh;
        Refresh();
        dialog.ShowDialog();
    }
    UIElement PatchMatrix()
    {
        var graph = new PipelineGraph(store.Session);
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new()
        {
            Width = new GridLength(190)
        });
        foreach (var bus in store.Session.Buses)
            grid.ColumnDefinitions.Add(new()
            {
                Width = new GridLength(108)
            });
        var sources = graph.Nodes.Where(n => n.Kind != "output").ToList();
        for (int i = 0; i <= sources.Count; i++)
            grid.RowDefinitions.Add(new()
            {
                Height = GridLength.Auto
            });
        void Cell(UIElement element, int row, int column)
        {
            Grid.SetRow(element, row);
            Grid.SetColumn(element, column);
            grid.Children.Add(element);
        }
        Cell(Ui.Text("SOURCE → BUS", 10, Theme.Muted), 0, 0);
        for (int column = 0; column < store.Session.Buses.Count; column++)
            Cell(Ui.Text(store.Session.Buses[column].Name, 12), 0, column + 1);
        for (int row = 0; row < sources.Count; row++)
        {
            var source = sources[row];
            Cell(Ui.Text(NodeName(source), 13, NodeColor(source)), row + 1, 0);
            for (int column = 0; column < store.Session.Buses.Count; column++)
            {
                var bus = store.Session.Buses[column];
                var target = new PipelineNode("bus", bus.Id);
                var edge = graph.Edges.FirstOrDefault(e => e.Source == source && e.Destination == target);
                string? problem = PipelineGraph.ConnectionProblem(store.Session, source, target);
                bool excluded = edge is not null && graph.DirectlyExcluded(store.Session, edge);
                var button = Ui.Button(edge is null ? "+" : (excluded ? "⊘ " : "") + (edge.Off ? "Off" : $"{edge.GainDB:0.#} dB") + (edge.PreFader ? " PRE" : ""), () =>
                {
                    store.Edit(s => { var sends = PipelineGraph.Sends(s, source); if (sends.Any(x => x.BusID == target.Id)) sends.RemoveAll(x => x.BusID == target.Id); else sends.Add(new() { BusID = target.Id }); }, "Toggle patch");
                });
                button.ToolTip = edge is null ? problem ?? "Connect at 0 dB" : "Click to disconnect; right-click to edit level and pre/post";
                button.IsEnabled = edge is not null || problem is null;
                button.FontSize = 11;
                if (edge is not null)
                {
                    button.BorderBrush = excluded ? Brushes.DarkOrange : NodeColor(source);
                    button.Foreground = excluded ? Brushes.DarkOrange : Theme.Accent;
                    button.ContextMenu = new();
                    button.ContextMenu.Items.Add(Item("Connection settings…", () => EditPipelineEdge(edge)));
                }
                Cell(button, row + 1, column + 1);
            }
        }
        return new ScrollViewer { Content = Ui.Card(grid), HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
    }
}

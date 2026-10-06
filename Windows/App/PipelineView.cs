using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow
{
    double pipelineZoom = 1; double pipelineScrollX, pipelineScrollY;
    sealed record Node(string Key, string Name, string Kind, string Id);
    UIElement BuildPipeline()
    {
        var dock = new DockPanel();
        var canvas = new Canvas { Background = Theme.Background, Width = 1800, Height = 1400, AllowDrop = true };
        var scale = new ScaleTransform(pipelineZoom, pipelineZoom);
        canvas.LayoutTransform = scale;
        var scroll = new ScrollViewer { Content = canvas, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, CanContentScroll = false };
        void Zoom(double factor)
        {
            pipelineZoom = Math.Clamp(pipelineZoom * factor, .35, 2);
            scale.ScaleX = scale.ScaleY = pipelineZoom;
        }
        var tools = Ui.Row(Ui.Text("PIPELINE", 16), Ui.Button("−", () => Zoom(1 / 1.2)), Ui.Button("+", () => Zoom(1.2)), Ui.Button("100%", () => { pipelineZoom = 1; scale.ScaleX = scale.ScaleY = 1; }), Ui.Button("Arrange", () => store.Edit(s => { s.PipelineLayout ??= new(); s.PipelineLayout.Positions.Clear(); }, "Arrange Pipeline")), Ui.Button("+ Output", () => { var p = new StackPanel(); var combo = new ComboBox { ItemsSource = store.Devices.Where(x => x.Outputs > 0).ToList(), Margin = new Thickness(4) }; p.Children.Add(combo); Dialog("Add Pipeline Output", p, () => { if (combo.SelectedItem is Device d) CommitEdit(s => { s.PipelineLayout ??= new(); if (!s.PipelineLayout.Outputs.Contains(d.Uid)) s.PipelineLayout.Outputs.Add(d.Uid); }, "Add Pipeline output"); }).ShowDialog(); }));
        var header = new StackPanel { Margin = new Thickness(12) };
        header.Children.Add(tools);
        header.Children.Add(Ui.Text("Drag a block’s title to move it. Drag Connect onto a bus or output to patch. Click a cable to edit it. Middle-drag to pan; Ctrl+wheel to zoom.", 12, Theme.Muted));
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        dock.Children.Add(scroll);
        var nodes = new List<Node>();
        nodes.AddRange(store.Session.Strips.Select(s => new Node("strip:" + s.Id, s.Name, "strip", s.Id)));
        nodes.AddRange(store.Session.Buses.Select(b => new Node("bus:" + b.Id, b.Name, "bus", b.Id)));
        var outputIDs = new[] { store.Session.MonitorDeviceUID }.Concat(store.Session.Routes.Select(r => r.DestinationUID)).Concat(store.Session.PipelineLayout?.Outputs ?? []).Where(x => x.Length > 0).Distinct().ToList();
        nodes.AddRange(outputIDs.Select(id => new Node("output:" + id, store.Devices.FirstOrDefault(x => x.Uid == id)?.Name ?? "Output · offline", "output", id)));
        var ranks = store.Session.Buses.ToDictionary(b => b.Id, _ => 1);
        for (int pass = 0; pass < ranks.Count; ++pass)
        foreach (var b in store.Session.Buses)
        foreach (var send in b.Sends)
            ranks[send.BusID] = Math.Max(ranks[send.BusID], ranks[b.Id] + 1);
        int outputRank = ranks.Values.DefaultIfEmpty(1).Max() + 1;
        var rows = new Dictionary<int, int>();
        var positions = new Dictionary<string, Point>();
        var blocks = new Dictionary<string, Border>();
        var cables = new List<UIElement>();
        foreach (var node in nodes)
        {
            int column = node.Kind == "strip" ? 0 : node.Kind == "output" ? outputRank : ranks[node.Id];
            int row = rows.GetValueOrDefault(column);
            rows[column] = row + 1;
            var saved = store.Session.PipelineLayout?.Positions.GetValueOrDefault(node.Key);
            positions[node.Key] = saved is not null ? new(saved.X, saved.Y) : new(35 + column * 320, 30 + row * 185);
        }
        void DrawCables()
        {
            foreach (var cable in cables)
                canvas.Children.Remove(cable);
            cables.Clear();
            void Cable(string from, string to, string text, Action edit, bool excluded = false)
            {
                if (!positions.TryGetValue(from, out var a) || !positions.TryGetValue(to, out var b))
                    return;
                a = new(a.X + 255, a.Y + 65);
                b = new(b.X, b.Y + 65);
                double bend = Math.Max(45, Math.Abs(b.X - a.X) * .45);
                var geometry = new PathGeometry([new PathFigure(a, [new BezierSegment(new(a.X + bend, a.Y), new(b.X - bend, b.Y), b, true)], false)]);
                var path = new Path { Data = geometry, Stroke = excluded ? Theme.Muted : Theme.Accent, StrokeThickness = 3, Opacity = excluded ? .35 : .65, Cursor = Cursors.Hand, ToolTip = text + (excluded ? " · excluded by mix-minus" : "") };
                if (excluded)
                    path.StrokeDashArray = [3, 3];
                path.MouseLeftButtonUp += (_, e) => { e.Handled = true; edit(); };
                Panel.SetZIndex(path, -1);
                canvas.Children.Add(path);
                cables.Add(path);
                var label = Ui.Button(text, edit);
                label.FontSize = 10;
                label.Padding = new Thickness(4, 1, 4, 1);
                Canvas.SetLeft(label, (a.X + b.X) / 2 - 25);
                Canvas.SetTop(label, (a.Y + b.Y) / 2 - 10);
                Panel.SetZIndex(label, -1);
                canvas.Children.Add(label);
                cables.Add(label);
            }
            foreach (var strip in store.Session.Strips)
            foreach (var send in strip.Sends)
            {
                var bus = store.Session.Buses.Single(x => x.Id == send.BusID);
                var excluded = store.Session.Strips.FirstOrDefault(x => x.Id == bus.ExcludedStripID);
                Cable("strip:" + strip.Id, "bus:" + send.BusID, $"{send.GainDB:0.#} dB" + (send.PreFader ? " PRE" : ""), () => SendsDialog(strip.Id, false), excluded is not null && excluded.Source.Key == strip.Source.Key);
            }
            foreach (var bus in store.Session.Buses)
            foreach (var send in bus.Sends)
                Cable("bus:" + bus.Id, "bus:" + send.BusID, $"{send.GainDB:0.#} dB", () => SendsDialog(bus.Id, true));
            foreach (var route in store.Session.Routes)
                Cable(route.SourceKind + ":" + route.SourceID, "output:" + route.DestinationUID, $"{route.GainDB:0.#} dB · {ChannelText(route.Channels)}", () => RouteDialog(route.Id));
            canvas.Width = Math.Max(1200, positions.Values.Select(p => p.X + 350).DefaultIfEmpty(0).Max());
            canvas.Height = Math.Max(800, positions.Values.Select(p => p.Y + 250).DefaultIfEmpty(0).Max());
        }
        foreach (var node in nodes)
        {
            var panel = new StackPanel();
            var title = Ui.Text(node.Name, 16);
            title.Cursor = Cursors.SizeAll;
            panel.Children.Add(title);
            panel.Children.Add(Ui.Text(node.Kind.ToUpperInvariant(), 10, Theme.Muted));
            if (node.Kind != "output")
            {
                panel.Children.Add(NewMeter(node.Id, node.Kind == "bus"));
                var connect = Ui.Button("Connect →", () => { });
                connect.PreviewMouseLeftButtonDown += (_, e) => { DragDrop.DoDragDrop(connect, new DataObject("MixingDesk.Source", node.Key), DragDropEffects.Link); e.Handled = true; };
                var edit = Ui.Button("Settings", () => { if (node.Kind == "strip") ChannelDialog(node.Id); else BusDialog(node.Id); });
                panel.Children.Add(Ui.Row(edit, connect));
            }
            else
                panel.Children.Add(Ui.Text("Drop a source here to choose output channels.", 12, Theme.Muted));
            var card = Ui.Card(panel, 255);
            card.Margin = new Thickness(0);
            card.AllowDrop = node.Kind != "strip";
            Canvas.SetLeft(card, positions[node.Key].X);
            Canvas.SetTop(card, positions[node.Key].Y);
            canvas.Children.Add(card);
            blocks[node.Key] = card;
            Point origin = default, position = default;
            bool dragging = false;
            title.MouseLeftButtonDown += (_, e) => { dragging = true; origin = e.GetPosition(canvas); position = positions[node.Key]; title.CaptureMouse(); e.Handled = true; };
            title.MouseMove += (_, e) => { if (!dragging) return; var now = e.GetPosition(canvas); var next = new Point(Math.Clamp(position.X + now.X - origin.X, 0, 999000), Math.Clamp(position.Y + now.Y - origin.Y, 0, 999000)); positions[node.Key] = next; Canvas.SetLeft(card, next.X); Canvas.SetTop(card, next.Y); DrawCables(); };
            title.MouseLeftButtonUp += (_, e) => { if (!dragging) return; dragging = false; title.ReleaseMouseCapture(); var next = positions[node.Key]; store.Edit(s => { s.PipelineLayout ??= new(); s.PipelineLayout.Positions[node.Key] = new() { X = next.X, Y = next.Y }; }, "Move Pipeline block", false); e.Handled = true; };
            card.DragOver += (_, e) => { e.Effects = e.Data.GetDataPresent("MixingDesk.Source") ? DragDropEffects.Link : DragDropEffects.None; e.Handled = true; };
            card.Drop += (_, e) =>
            {
                if (e.Data.GetData("MixingDesk.Source") is not string source)
                    return;
                e.Handled = true;
                var parts = source.Split(':', 2);
                if (parts.Length != 2)
                    return;
                if (node.Kind == "output")
                    RouteDialog(null, parts[0], parts[1], node.Id);
                else if (node.Kind == "bus")
                    store.Edit(s => { var sends = parts[0] == "strip" ? s.Strips.Single(x => x.Id == parts[1]).Sends : s.Buses.Single(x => x.Id == parts[1]).Sends; if (sends.All(x => x.BusID != node.Id)) sends.Add(new() { BusID = node.Id }); }, "Connect Pipeline send");
            };
        }
        DrawCables();
        Point panOrigin = default;
        double panX = 0, panY = 0;
        bool panning = false;
        scroll.PreviewMouseDown += (_, e) => { if (e.ChangedButton != MouseButton.Middle) return; panning = true; panOrigin = e.GetPosition(scroll); panX = scroll.HorizontalOffset; panY = scroll.VerticalOffset; scroll.CaptureMouse(); e.Handled = true; };
        scroll.PreviewMouseMove += (_, e) => { if (!panning) return; var p = e.GetPosition(scroll); scroll.ScrollToHorizontalOffset(panX + panOrigin.X - p.X); scroll.ScrollToVerticalOffset(panY + panOrigin.Y - p.Y); };
        scroll.PreviewMouseUp += (_, e) => { if (e.ChangedButton == MouseButton.Middle) { panning = false; scroll.ReleaseMouseCapture(); } };
        scroll.PreviewMouseWheel += (_, e) => { if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return; Zoom(e.Delta > 0 ? 1.1 : 1 / 1.1); e.Handled = true; };
        scroll.ScrollChanged += (_, _) => { pipelineScrollX = scroll.HorizontalOffset; pipelineScrollY = scroll.VerticalOffset; };
        scroll.Loaded += (_, _) => { scroll.ScrollToHorizontalOffset(pipelineScrollX); scroll.ScrollToVerticalOffset(pipelineScrollY); };
        return dock;
    }
}

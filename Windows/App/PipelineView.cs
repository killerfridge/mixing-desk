using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow
{
    const double NodeWidth = 240, NodeHeight = 238, PortY = 64;
    double pipelineZoom = .85, pipelineScrollX, pipelineScrollY;
    string? selectedPipelineNode, selectedPipelineEdge;
    Action<KeyEventArgs>? pipelineKeys;
    string NodeName(PipelineNode n) => n.Kind == "strip" ? store.Session.Strips.FirstOrDefault(x => x.Id == n.Id)?.Name ?? "Removed channel" : n.Kind == "bus" ? store.Session.Buses.FirstOrDefault(x => x.Id == n.Id)?.Name ?? "Removed bus" : store.Devices.FirstOrDefault(x => x.Uid == n.Id)?.Name ?? "Saved output · offline";
    Brush NodeColor(PipelineNode n) => Theme.Color(n.Kind == "strip" ? store.Session.Strips.FirstOrDefault(x => x.Id == n.Id)?.Color ?? "teal" : n.Kind == "output" ? "output" : "amber");
    string EdgeName(PipelineEdge e) => $"{NodeName(e.Source)} → {NodeName(e.Destination)} · {(e.Off ? "Off" : $"{e.GainDB:0.#} dB")}" + (e.Source.Kind == "strip" ? e.PreFader ? " · PRE" : " · POST" : "") + (e.Channels.Length > 0 ? " · Ch " + ChannelText(e.Channels) : "");
    void RemovePipelineNode(PipelineNode node) => store.Edit(s => PipelineGraph.Remove(s, node), "Remove " + NodeName(node));
    void RemovePipelineEdge(PipelineEdge edge) => store.Edit(s => { if (edge.RouteId is string route) s.Routes.RemoveAll(r => r.Id == route); else PipelineGraph.Sends(s, edge.Source).RemoveAll(x => x.BusID == edge.Destination.Id); }, "Disconnect cable");
    void EditPipelineEdge(PipelineEdge edge)
    {
        selectedPipelineNode = null;
        selectedPipelineEdge = edge.Key;
        if (edge.RouteId is string route)
        {
            RouteDialog(route);
            return;
        }
        var p = new StackPanel();
        p.Children.Add(Ui.Text(NodeName(edge.Source) + " → " + NodeName(edge.Destination), 20));
        double gain = edge.GainDB;
        p.Children.Add(Ui.Level("CONNECTION LEVEL · dB", gain, x => gain = x, -90, 12));
        var pre = Ui.Check("Pre-fader", edge.PreFader, _ => { });
        if (edge.Source.Kind == "strip")
            p.Children.Add(pre);
        var window = Dialog("Connection Settings", p, () => CommitEdit(s => { var send = PipelineGraph.Sends(s, edge.Source).Single(x => x.BusID == edge.Destination.Id); send.GainDB = gain; send.PreFader = edge.Source.Kind == "strip" && pre.IsChecked == true; }, "Edit connection"), "Apply");
        p.Children.Add(Ui.Button("Disconnect", () => { RemovePipelineEdge(edge); window.Close(); }));
        window.ShowDialog();
    }
    void AddPipelineOutput()
    {
        var p = new StackPanel();
        p.Children.Add(Ui.Text("Display an output, then connect a channel or bus to it. This does not change your monitor or start audio.", 13));
        var combo = new ComboBox { ItemsSource = store.Devices.Where(x => x.Outputs > 0).ToList(), Margin = new Thickness(4) };
        p.Children.Add(combo);
        Dialog("Add Output Device", p, () => { Session.Require(combo.SelectedItem is Device, "Choose an output device."); var d = (Device)combo.SelectedItem; CommitEdit(s => { s.PipelineLayout ??= new(); if (!s.PipelineLayout.Outputs.Contains(d.Uid)) s.PipelineLayout.Outputs.Add(d.Uid); }, "Show output device"); }, "Add").ShowDialog();
    }
    UIElement BuildPipeline()
    {
        var graph = new PipelineGraph(store.Session);
        if (!graph.Nodes.Any(n => n.Key == selectedPipelineNode))
            selectedPipelineNode = null;
        if (!graph.Edges.Any(e => e.Key == selectedPipelineEdge))
            selectedPipelineEdge = null;
        var positions = graph.Arrange().ToDictionary(p => p.Key, p => new Point(p.Value.X, p.Value.Y));
        foreach (var n in graph.Nodes)
            if (store.Session.PipelineLayout?.Positions.GetValueOrDefault(n.Key) is PipelinePosition saved)
                positions[n.Key] = new(saved.X, saved.Y);
        var canvas = new Canvas { Background = Theme.Background, Focusable = true, ClipToBounds = false, IsManipulationEnabled = true };
        var scale = new ScaleTransform(pipelineZoom, pipelineZoom);
        canvas.LayoutTransform = scale;
        var scroll = new ScrollViewer { Content = canvas, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, CanContentScroll = false, PanningMode = PanningMode.None };
        var cards = new Dictionary<string, Border>();
        var wires = new List<UIElement>();
        PipelineNode? connecting = null;
        Point? pointer = null;
        var compatible = new HashSet<string>();
        var zoomLabel = Ui.Text($"{pipelineZoom:P0}", 11, Theme.Muted);
        void Zoom(double next, Point? anchor = null)
        {
            var center = anchor ?? new Point(scroll.ViewportWidth / 2, scroll.ViewportHeight / 2);
            var world = new Point((scroll.HorizontalOffset + center.X) / pipelineZoom, (scroll.VerticalOffset + center.Y) / pipelineZoom);
            pipelineZoom = Math.Clamp(next, .15, 2);
            scale.ScaleX = scale.ScaleY = pipelineZoom;
            zoomLabel.Text = $"{pipelineZoom:P0}";
            scroll.Dispatcher.BeginInvoke(() => { scroll.ScrollToHorizontalOffset(world.X * pipelineZoom - center.X); scroll.ScrollToVerticalOffset(world.Y * pipelineZoom - center.Y); }, DispatcherPriority.Loaded);
        }
        void Fit()
        {
            double width = positions.Values.Select(p => p.X + NodeWidth + 40).DefaultIfEmpty(600).Max();
            double height = positions.Values.Select(p => p.Y + NodeHeight + 40).DefaultIfEmpty(400).Max();
            Zoom(Math.Min(1.2, Math.Min(scroll.ViewportWidth / width, scroll.ViewportHeight / height)), new Point());
            scroll.Dispatcher.BeginInvoke(() => { scroll.ScrollToHorizontalOffset(0); scroll.ScrollToVerticalOffset(0); }, DispatcherPriority.Loaded);
        }
        PathGeometry Curve(Point a, Point b)
        {
            double bend = Math.Max(75, Math.Abs(b.X - a.X) / 2);
            return new([new PathFigure(a, [new BezierSegment(new(a.X + bend, a.Y), new(b.X - bend, b.Y), b, true)], false)]);
        }
        Point Port(PipelineNode n, bool outgoing) => new(positions[n.Key].X + (outgoing ? NodeWidth : 0), positions[n.Key].Y + PortY);
        void Draw()
        {
            foreach (var w in wires)
                canvas.Children.Remove(w);
            wires.Clear();
            var selected = graph.Nodes.FirstOrDefault(n => n.Key == selectedPipelineNode);
            var trace = selected is null ? null : graph.Trace(store.Session, selected);
            foreach (var edge in graph.Edges)
            {
                bool blocked = graph.DirectlyExcluded(store.Session, edge) || trace?.Excluded.Contains(edge.Key) == true;
                bool focused = selectedPipelineEdge == edge.Key || trace?.Reached.Contains(edge.Key) == true;
                var color = blocked ? Brushes.DarkOrange : NodeColor(edge.Source);
                var a = Port(edge.Source, true);
                var b = Port(edge.Destination, false);
                var geometry = Curve(a, b);
                var hit = new Path { Data = geometry, Stroke = Brushes.Transparent, StrokeThickness = 16, Cursor = Cursors.Hand, ToolTip = EdgeName(edge) + (blocked ? " · excluded from this source’s path" : "") };
                var wire = new Path { Data = geometry, Stroke = color, StrokeThickness = focused ? 3 : 1.7, Opacity = edge.Off ? .22 : trace is not null && !focused ? .12 : focused ? 1 : .6, IsHitTestVisible = false };
                if (edge.Off || blocked)
                    wire.StrokeDashArray = [4, 3];
                hit.MouseLeftButtonUp += (_, e) => { e.Handled = true; selectedPipelineEdge = edge.Key; selectedPipelineNode = null; Draw(); EditPipelineEdge(edge); };
                foreach (var item in new UIElement[] { hit, wire })
                {
                    Panel.SetZIndex(item, -1);
                    canvas.Children.Add(item);
                    wires.Add(item);
                }
                var arrow = new Polyline { Points = [new(b.X - 8, b.Y - 4), b, new(b.X - 8, b.Y + 4)], Stroke = color, StrokeThickness = 1.5, Opacity = wire.Opacity, IsHitTestVisible = false };
                Panel.SetZIndex(arrow, -1);
                canvas.Children.Add(arrow);
                wires.Add(arrow);
                if (blocked)
                {
                    var badge = Ui.Text("⊘", 16, Brushes.DarkOrange);
                    badge.IsHitTestVisible = false;
                    Canvas.SetLeft(badge, b.X - 29);
                    Canvas.SetTop(badge, b.Y - 16);
                    canvas.Children.Add(badge);
                    wires.Add(badge);
                }
            }
            if (connecting is not null && pointer is Point end)
            {
                var preview = new Path { Data = Curve(Port(connecting, true), end), Stroke = Theme.Accent, StrokeThickness = 2, StrokeDashArray = [4, 3], IsHitTestVisible = false };
                canvas.Children.Add(preview);
                wires.Add(preview);
            }
            foreach (var n in graph.Nodes)
                if (cards.TryGetValue(n.Key, out var card))
                {
                    card.BorderBrush = compatible.Contains(n.Key) ? Brushes.LimeGreen : selectedPipelineNode == n.Key ? NodeColor(n) : Theme.Line;
                    card.BorderThickness = new Thickness(compatible.Contains(n.Key) || selectedPipelineNode == n.Key ? 2 : 1);
                }
            canvas.Width = Math.Max(1000, positions.Values.Select(p => p.X + NodeWidth + 60).DefaultIfEmpty(1000).Max());
            canvas.Height = Math.Max(650, positions.Values.Select(p => p.Y + NodeHeight + 60).DefaultIfEmpty(650).Max());
        }
        string? Problem(PipelineNode source, PipelineNode target) => target.Kind == "output" && !store.Devices.Any(d => d.Uid == target.Id && d.Outputs > 0) ? "Reconnect this output before adding a route." : PipelineGraph.ConnectionProblem(store.Session, source, target);
        void Cancel()
        {
            connecting = null;
            pointer = null;
            compatible.Clear();
            Draw();
        }
        void Begin(PipelineNode n)
        {
            connecting = n;
            pointer = Port(n, true);
            compatible.Clear();
            foreach (var target in graph.Nodes)
            if (Problem(n, target) is null)
                compatible.Add(target.Key);
            selectedPipelineNode = n.Key;
            selectedPipelineEdge = null;
            Draw();
        }
        void Connect(PipelineNode target)
        {
            if (connecting is null)
                return;
            var source = connecting;
            string? problem = Problem(source, target);
            Cancel();
            if (problem is not null)
            {
                store.Info(problem);
                return;
            }
            if (target.Kind == "output")
                RouteDialog(null, source.Kind, source.Id, target.Id);
            else
            {
                var existing = graph.Edges.FirstOrDefault(e => e.Source == source && e.Destination == target);
                if (existing is not null)
                    EditPipelineEdge(existing);
                else
                    store.Edit(s => PipelineGraph.Sends(s, source).Add(new() { BusID = target.Id }), "Connect pipeline");
            }
        }
        void ChooseConnection(PipelineNode source)
        {
            var p = new StackPanel();
            var targets = graph.Nodes.Where(n => n.Kind != "strip" && n != source).ToList();
            var combo = new ComboBox { ItemsSource = targets.Select(n => new Choice(n.Key, NodeName(n))).ToList(), SelectedIndex = targets.Count > 0 ? 0 : -1, Margin = new Thickness(4) };
            p.Children.Add(combo);
            var dialog = Dialog("Connect " + NodeName(source), p);
            p.Children.Add(Ui.Button("Connect", () => { if (combo.SelectedItem is Choice c) { var target = targets.Single(n => n.Key == c.Id); if (Problem(source, target) is string error) { store.Info(error); return; } dialog.Close(); Begin(source); Connect(target); } }));
            dialog.ShowDialog();
        }
        ContextMenu Actions(PipelineNode node)
        {
            var menu = new ContextMenu();
            if (node.Kind != "output")
            {
                menu.Items.Add(Item("Settings…", () => { if (node.Kind == "strip") ChannelDialog(node.Id); else BusDialog(node.Id); }));
                menu.Items.Add(Item("Edit effects…", () => InsertsDialog(node.Id, node.Kind == "bus")));
                menu.Items.Add(Item("Connect to…", () => ChooseConnection(node)));
            }
            else
            {
                var monitor = Item("Use for monitoring", () => { var device = store.Devices.Single(d => d.Uid == node.Id); store.Edit(s => s.SelectMonitor(device.Uid, device.Outputs), "Select monitor"); });
                monitor.IsEnabled = store.Devices.Any(d => d.Uid == node.Id && d.Outputs > 0);
                menu.Items.Add(monitor);
            }
            var connections = new MenuItem { Header = "Connections" };
            foreach (var e in graph.Edges.Where(e => e.Source == node || e.Destination == node))
                connections.Items.Add(Item(EdgeName(e), () => EditPipelineEdge(e)));
            connections.IsEnabled = connections.Items.Count > 0;
            menu.Items.Add(connections);
            var remove = Item("Remove " + (node.Kind == "strip" ? "channel" : node.Kind), () => RemovePipelineNode(node));
            remove.IsEnabled = !store.Session.Buses.Any(b => node.Kind == "bus" && b.Id == node.Id && b.Kind == "monitor");
            menu.Items.Add(remove);
            return menu;
        }
        foreach (var node in graph.Nodes)
        {
            var strip = store.Session.Strips.FirstOrDefault(s => node.Kind == "strip" && s.Id == node.Id);
            var bus = store.Session.Buses.FirstOrDefault(b => node.Kind == "bus" && b.Id == node.Id);
            var panel = new StackPanel();
            var heading = new DockPanel();
            var more = Ui.Button("···", () => { });
            more.Padding = new Thickness(5, 0, 5, 0);
            more.ContextMenu = Actions(node);
            more.Click += (_, _) => { more.ContextMenu.PlacementTarget = more; more.ContextMenu.IsOpen = true; };
            DockPanel.SetDock(more, Dock.Right);
            heading.Children.Add(more);
            var title = new StackPanel { Cursor = Cursors.SizeAll, Background = Brushes.Transparent };
            var kindLabel = Ui.Text(node.Kind == "strip" ? "CHANNEL" : node.Kind.ToUpperInvariant(), 8, NodeColor(node));
            kindLabel.Margin = new Thickness(2, 0, 2, 1);
            title.Children.Add(kindLabel);
            var name = Ui.Text(NodeName(node), 12);
            name.Margin = new Thickness(2, 0, 2, 1);
            name.FontWeight = FontWeights.SemiBold;
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            name.TextWrapping = TextWrapping.NoWrap;
            title.Children.Add(name);
            heading.Children.Add(title);
            panel.Children.Add(heading);
            string detail = strip is not null ? (store.SourceOnline(strip.Source) ? "● " : "○ ") + store.SourceName(strip.Source) : bus is not null ? bus.Kind == "monitor" ? "Monitor mix · solo applies here" : bus.Kind == "call" ? "Call mix-minus" : "Independent mix" : store.Devices.FirstOrDefault(d => d.Uid == node.Id) is Device d ? $"{d.Outputs} output channels" : "Offline · saved routes retained";
            if (strip is not null)
            {
                var source = Ui.Button(detail + " ▾", () => ChannelDialog(node.Id));
                source.Content = new TextBlock { Text = detail + " ▾", FontSize = 10, TextTrimming = TextTrimming.CharacterEllipsis };
                source.Padding = new Thickness(2);
                source.Margin = new Thickness(1, 3, 1, 3);
                source.HorizontalContentAlignment = HorizontalAlignment.Left;
                panel.Children.Add(source);
            }
            else
            {
                var subtitle = Ui.Text(detail, 10, Theme.Muted);
                subtitle.Height = 24;
                subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
                subtitle.TextWrapping = TextWrapping.NoWrap;
                panel.Children.Add(subtitle);
            }
            var chain = strip?.Inserts ?? bus?.Inserts;
            if (chain is not null)
            {
                var effects = Ui.Button(chain.Count == 0 ? "⊕  Add effects…" : string.Join("\n", chain.Select((s, i) => $"{i + 1}  {s.DisplayName}{(s.Bypassed ? "  · BYP" : "")}")), () => InsertsDialog(node.Id, bus is not null));
                effects.FontSize = 10;
                effects.Height = chain.Count == 4 ? 64 : 50;
                effects.Margin = new Thickness(3, 1, 3, 1);
                effects.HorizontalContentAlignment = HorizontalAlignment.Left;
                effects.VerticalContentAlignment = VerticalAlignment.Top;
                effects.Padding = new Thickness(5);
                panel.Children.Add(effects);
                var meter = NewMeter(node.Id, bus is not null);
                meter.Compact = true;
                meter.Height = 25;
                meter.Margin = new Thickness(4, 4, 4, 0);
                panel.Children.Add(meter);
                var level = Ui.CompactLevel("LEVEL", strip?.FaderDB ?? bus!.GainDB, x => store.Edit(s => { if (strip is not null) s.Strips.Single(c => c.Id == node.Id).FaderDB = x; else s.Buses.Single(b => b.Id == node.Id).GainDB = x; }, rebuild: false), -90, 12, compact: true);
                panel.Children.Add(level);
                var controls = Ui.Row(Ui.Toggle("M", strip?.Muted ?? bus!.Muted, x => store.Edit(s => { if (strip is not null) s.Strips.Single(c => c.Id == node.Id).Muted = x; else s.Buses.Single(b => b.Id == node.Id).Muted = x; }, rebuild: false), "Mute " + NodeName(node)));
                if (strip is not null)
                {
                    controls.Children.Add(Ui.Toggle("S", strip.Solo, x => store.Edit(s => s.Strips.Single(c => c.Id == node.Id).Solo = x, rebuild: false), "Solo " + strip.Name));
                    controls.Children.Add(Ui.Text("TRIM", 9, Theme.Muted));
                    controls.Children.Add(Ui.Number(strip.TrimDB, x => store.Edit(s => s.Strips.Single(c => c.Id == node.Id).TrimDB = x, rebuild: false), -24, 24, "Input trim"));
                }
                else
                    controls.Children.Add(Ui.Text(bus!.ExcludedStripID.Length > 0 ? "⊘ " + (store.Session.Strips.FirstOrDefault(s => s.Id == bus.ExcludedStripID)?.Name ?? "Return") : "STEREO MIX", 9, bus.ExcludedStripID.Length > 0 ? Brushes.DarkOrange : Theme.Muted));
                panel.Children.Add(controls);
            }
            else
            {
                var routes = store.Session.Routes.Where(r => r.DestinationUID == node.Id).ToList();
                panel.Children.Add(Ui.Text($"{routes.Count} connections", 14));
                foreach (var r in routes.Take(3))
                    panel.Children.Add(Ui.Text($"Ch {ChannelText(r.Channels)} · {(r.Channels.Length == 1 ? "Mono" : "Stereo")}", 11, Theme.Muted));
                if (routes.Count == 0)
                    panel.Children.Add(Ui.Text("Drag a cable to the input port to choose output channels.", 12, Theme.Muted));
                panel.Children.Add(Ui.Text(store.Session.MonitorDeviceUID == node.Id ? "◉ Monitoring / clock" : "OUTPUT DESTINATION", 11, Theme.Accent));
            }
            var card = Ui.Card(panel, NodeWidth);
            card.Height = NodeHeight;
            card.Margin = new Thickness(0);
            card.Padding = new Thickness(10);
            card.ContextMenu = Actions(node);
            var holder = new Canvas { Width = NodeWidth, Height = NodeHeight, Tag = node };
            holder.Children.Add(card);
            cards[node.Key] = card;
            Canvas.SetLeft(holder, positions[node.Key].X);
            Canvas.SetTop(holder, positions[node.Key].Y);
            canvas.Children.Add(holder);
            var accent = new Border { Width = NodeWidth - 28, Height = 3, Background = NodeColor(node), CornerRadius = new CornerRadius(2), IsHitTestVisible = false };
            Canvas.SetLeft(accent, 14);
            holder.Children.Add(accent);
            card.MouseLeftButtonUp += (_, _) => { selectedPipelineNode = node.Key; selectedPipelineEdge = null; canvas.Focus(); Draw(); };
            Point origin = default, position = default;
            bool dragging = false, moved = false;
            title.MouseLeftButtonDown += (_, e) => { selectedPipelineNode = node.Key; selectedPipelineEdge = null; origin = e.GetPosition(canvas); position = positions[node.Key]; dragging = true; moved = false; title.CaptureMouse(); e.Handled = true; Draw(); };
            title.MouseMove += (_, e) => { if (!dragging) return; var delta = e.GetPosition(canvas) - origin; if (!moved && delta.Length < 4) return; moved = true; var next = new Point(Math.Clamp(position.X + delta.X, 10, 999000), Math.Clamp(position.Y + delta.Y, 10, 999000)); positions[node.Key] = next; Canvas.SetLeft(holder, next.X); Canvas.SetTop(holder, next.Y); Draw(); };
            title.MouseLeftButtonUp += (_, e) => { if (!dragging) return; dragging = false; title.ReleaseMouseCapture(); if (moved) { var next = positions[node.Key]; store.Edit(s => { s.PipelineLayout ??= new(); s.PipelineLayout.Positions[node.Key] = new() { X = next.X, Y = next.Y }; }, "Move pipeline block", true, false); } e.Handled = true; canvas.Focus(); };
            title.LostMouseCapture += (_, _) => { dragging = false; };
            void AddPort(bool outgoing)
            {
                var port = Ui.Button("", () => { if (!outgoing && connecting is not null) Connect(node); else if (outgoing) Begin(node); });
                port.Content = new Ellipse { Stroke = Theme.Accent, StrokeThickness = 2, Fill = Theme.Recessed, Width = 12, Height = 12 };
                port.Width = 22;
                port.Height = 22;
                port.Padding = new Thickness(0);
                port.Margin = new Thickness(0);
                port.Background = Brushes.Transparent;
                port.BorderThickness = new Thickness(0);
                port.ToolTip = outgoing ? "Drag or click to connect " + NodeName(node) : "Connect into " + NodeName(node);
                AutomationProperties.SetName(port, (outgoing ? "Output port: " : "Input port: ") + NodeName(node));
                Canvas.SetLeft(port, outgoing ? NodeWidth - 11 : -11);
                Canvas.SetTop(port, PortY - 11);
                holder.Children.Add(port);
                if (!outgoing)
                    return;
                Point down = default;
                bool pressed = false, dragged = false;
                port.PreviewMouseLeftButtonDown += (_, e) => { Begin(node); down = e.GetPosition(canvas); pressed = true; dragged = false; port.CaptureMouse(); e.Handled = true; };
                port.PreviewMouseMove += (_, e) => { if (!pressed) return; pointer = e.GetPosition(canvas); dragged |= (pointer.Value - down).Length > 4; Draw(); e.Handled = true; };
                port.PreviewMouseLeftButtonUp += (_, e) =>
                {
                    if (!pressed)
                        return;
                    pressed = false;
                    port.ReleaseMouseCapture();
                    e.Handled = true;
                    if (!dragged)
                    {
                        canvas.Focus();
                        return;
                    }
                    var at = e.GetPosition(canvas);
                    var target = graph.Nodes.LastOrDefault(n => n != node && new Rect(new Point(positions[n.Key].X - 11, positions[n.Key].Y), new Size(NodeWidth + 22, NodeHeight)).Contains(at));
                    if (target is null)
                        Cancel();
                    else
                        Connect(target);
                };
                port.LostMouseCapture += (_, _) => { if (pressed) { pressed = false; Cancel(); } };
            }
            if (node.Kind != "strip")
                AddPort(false);
            if (node.Kind != "output")
                AddPort(true);
        }
        var toolbar = new WrapPanel();
        toolbar.Children.Add(Ui.Button("+ Channel", AddChannel));
        toolbar.Children.Add(Ui.Button("+ Bus", AddBus));
        toolbar.Children.Add(Ui.Button("+ Output", AddPipelineOutput));
        var connectionsMenu = new ContextMenu();
        foreach (var e in graph.Edges)
            connectionsMenu.Items.Add(Item(EdgeName(e), () => EditPipelineEdge(e)));
        var connectionsButton = Ui.Button($"Connections · {graph.Edges.Count}", () => { connectionsMenu.IsOpen = true; });
        connectionsMenu.PlacementTarget = connectionsButton;
        toolbar.Children.Add(connectionsButton);
        var undo = Ui.Button("↶", () => store.Undo(false));
        undo.ToolTip = "Undo routing · Ctrl+Z";
        undo.IsEnabled = store.History.CanUndo;
        toolbar.Children.Add(undo);
        var redo = Ui.Button("↷", () => store.Undo(true));
        redo.ToolTip = "Redo routing · Ctrl+Y";
        redo.IsEnabled = store.History.CanRedo;
        toolbar.Children.Add(redo);
        toolbar.Children.Add(Ui.Button("−", () => Zoom(pipelineZoom / 1.2)));
        toolbar.Children.Add(zoomLabel);
        toolbar.Children.Add(Ui.Button("+", () => Zoom(pipelineZoom * 1.2)));
        toolbar.Children.Add(Ui.Button("Fit All", Fit));
        toolbar.Children.Add(Ui.Button("Auto Arrange", () => { store.Edit(s => { s.PipelineLayout ??= new(); s.PipelineLayout.Positions = new PipelineGraph(s).Arrange(); }, "Arrange pipeline", true, false); }));
        var header = new StackPanel { Margin = new Thickness(16, 6, 16, 6) };
        var headingRow = new WrapPanel();
        headingRow.Children.Add(Ui.Text("Signal pipeline", 22));
        var headerSubtitle = Ui.Text("Connect your sources, mixes, and outputs.", 12, Theme.Muted);
        headerSubtitle.VerticalAlignment = VerticalAlignment.Center;
        headerSubtitle.Margin = new Thickness(12, 4, 4, 4);
        headingRow.Children.Add(headerSubtitle);
        header.Children.Add(headingRow);
        header.Children.Add(toolbar);
        var dock = new DockPanel();
        DockPanel.SetDock(header, Dock.Top);
        dock.Children.Add(header);
        var hints = Ui.Text("Drag ports to connect · Click a cable to edit · Select a block to trace · Delete removes selection · Ctrl+wheel zooms · Drag empty space to pan", 11, Theme.Muted);
        DockPanel.SetDock(hints, Dock.Bottom);
        dock.Children.Add(hints);
        dock.Children.Add(scroll);
        bool panning = false;
        Point panOrigin = default;
        double panX = 0, panY = 0;
        scroll.PreviewMouseDown += (_, e) => { if (e.ChangedButton != MouseButton.Middle && !(e.ChangedButton == MouseButton.Left && ReferenceEquals(e.OriginalSource, canvas))) return; if (connecting is not null) Cancel(); panning = true; panOrigin = e.GetPosition(scroll); panX = scroll.HorizontalOffset; panY = scroll.VerticalOffset; selectedPipelineNode = null; selectedPipelineEdge = null; canvas.Focus(); scroll.CaptureMouse(); Draw(); e.Handled = true; };
        scroll.PreviewMouseMove += (_, e) => { if (!panning) return; var p = e.GetPosition(scroll); scroll.ScrollToHorizontalOffset(panX + panOrigin.X - p.X); scroll.ScrollToVerticalOffset(panY + panOrigin.Y - p.Y); };
        scroll.PreviewMouseUp += (_, e) => { if (!panning) return; panning = false; scroll.ReleaseMouseCapture(); e.Handled = true; };
        scroll.LostMouseCapture += (_, _) => panning = false;
        scroll.PreviewMouseWheel += (_, e) => { if ((Keyboard.Modifiers & ModifierKeys.Control) != 0) { Zoom(pipelineZoom * (e.Delta > 0 ? 1.1 : 1 / 1.1), e.GetPosition(scroll)); e.Handled = true; } else if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0) { scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - e.Delta); e.Handled = true; } };
        canvas.ManipulationStarting += (_, e) => { e.ManipulationContainer = scroll; e.Mode = ManipulationModes.Scale | ManipulationModes.Translate; e.Handled = true; };
        canvas.ManipulationDelta += (_, e) =>
        {
            double factor = Math.Sqrt(e.DeltaManipulation.Scale.X * e.DeltaManipulation.Scale.Y);
            if (double.IsFinite(factor) && factor > 0 && Math.Abs(factor - 1) > .001)
                Zoom(pipelineZoom * factor, e.ManipulationOrigin);
            scroll.ScrollToHorizontalOffset(scroll.HorizontalOffset - e.DeltaManipulation.Translation.X);
            scroll.ScrollToVerticalOffset(scroll.VerticalOffset - e.DeltaManipulation.Translation.Y);
            e.Handled = true;
        };
        scroll.ScrollChanged += (_, _) => { pipelineScrollX = scroll.HorizontalOffset; pipelineScrollY = scroll.VerticalOffset; };
        double restoreX = pipelineScrollX, restoreY = pipelineScrollY;
        scroll.Loaded += (_, _) => { scroll.ScrollToHorizontalOffset(restoreX); scroll.ScrollToVerticalOffset(restoreY); };
        pipelineKeys = e => { if (e.Key == Key.Escape) { Cancel(); e.Handled = true; } else if (e.Key == Key.Delete) { if (graph.Edges.FirstOrDefault(x => x.Key == selectedPipelineEdge) is PipelineEdge edge) RemovePipelineEdge(edge); else if (graph.Nodes.FirstOrDefault(x => x.Key == selectedPipelineNode) is PipelineNode node) RemovePipelineNode(node); e.Handled = true; } };
        Draw();
        return dock;
    }
}

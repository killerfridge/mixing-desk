using System;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using MixingDesk.Models;
namespace MixingDesk;

sealed class EqGraph : FrameworkElement
{
    public double[] Points { get; set; } = [];
    public bool Bypassed
    {
        get; set;
    }
    public EqGraph()
    {
        Height = 180;
        MinWidth = 300;
        Margin = new Thickness(4);
    }
    protected override void OnRender(DrawingContext dc)
    {
        double w = Math.Max(1, ActualWidth - 54), h = Math.Max(1, ActualHeight - 40), left = 36, top = 15;
        dc.DrawRoundedRectangle(Theme.Recessed, null, new Rect(0, 0, ActualWidth, ActualHeight), 8, 8);
        double limit = Math.Max(24, Math.Ceiling(Points.Select(Math.Abs).DefaultIfEmpty(0).Max() / 6) * 6);
        double Y(double db) => top + h / 2 - db / limit * h / 2;
        void Text(string text, double x, double y) => dc.DrawText(new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 10, Theme.Muted, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(x, y));
        foreach (double db in new[] { -limit, 0, limit })
        {
            dc.DrawLine(new Pen(Theme.Line, 1), new(left, Y(db)), new(left + w, Y(db)));
            Text(db.ToString("+0;-0;0"), 3, Y(db) - 7);
        }
        foreach (double hz in new[] { 20d, 100, 1000, 10000, 20000 })
        {
            double x = left + Math.Log10(hz / 20) / 3 * w;
            dc.DrawLine(new Pen(Theme.Line, 1), new(x, top), new(x, top + h));
            Text(hz >= 1000 ? (hz / 1000) + "k" : hz.ToString(), x - 10, top + h + 8);
        }
        if (Points.Length == 0)
            return;
        var curve = new StreamGeometry();
        using (var ctx = curve.Open())
        {
            ctx.BeginFigure(new(left, Y(Bypassed ? 0 : Points[0])), false, false);
            for (int i = 1; i < Points.Length; i++)
                ctx.LineTo(new(left + i * w / (Points.Length - 1), Y(Bypassed ? 0 : Points[i])), true, false);
        }
        dc.DrawGeometry(null, new Pen(Bypassed ? Theme.Muted : Theme.Accent, 2.2), curve);
    }
}
sealed partial class MainWindow
{
    void EqDialog(string id)
    {
        var slot = store.Session.AllInserts.Single(x => x.Id == id);
        var eq = slot.ReadEq();
        var panel = new StackPanel();
        var graph = new EqGraph { Bypassed = slot.Bypassed };
        var controls = new StackPanel();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(90) };
        int revision = 0;
        bool closed = false;
        async System.Threading.Tasks.Task Response()
        {
            int current = ++revision;
            try
            {
                var response = await store.PluginCall("eqResponse", JsonSerializer.SerializeToNode(eq, Session.Options)!.AsObject());
                if (!closed && current == revision)
                {
                    graph.Points = response!.AsArray().Select(n => n!.GetValue<double>()).ToArray();
                    graph.InvalidateVisual();
                }
            }
            catch (Exception e) { store.Error(e); }
        }
        void Changed()
        {
            store.Edit(s => s.AllInserts.Single(x => x.Id == id).WriteEq(eq), rebuild: false);
            ++revision;
            timer.Stop();
            timer.Start();
        }
        timer.Tick += async (_, _) => { timer.Stop(); await Response(); };
        void BuildControls()
        {
            controls.Children.Clear();
            var bands = new WrapPanel();
            foreach (var spec in new[] { ("LOW SHELF", "LowFrequency", "LowGain", 120d), ("MID BELL", "MidFrequency", "MidGain", 1000d), ("HIGH SHELF", "HighFrequency", "HighGain", 8000d) })
            {
                var frequency = typeof(EqSettings).GetProperty(spec.Item2)!;
                var gain = typeof(EqSettings).GetProperty(spec.Item3)!;
                var band = new StackPanel();
                band.Children.Add(Ui.Text(spec.Item1, 11, Theme.Accent));
                var readout = Ui.Text("", 12);
                void Label()
                {
                    double hz = (double)frequency.GetValue(eq)!;
                    readout.Text = hz >= 1000 ? $"{hz / 1000:0.00} kHz" : $"{hz:0} Hz";
                }
                Label();
                band.Children.Add(readout);
                band.Children.Add(Ui.Frequency((double)frequency.GetValue(eq)!, x => { frequency.SetValue(eq, x); Label(); Changed(); }, spec.Item4));
                band.Children.Add(Ui.Level("Gain · dB", (double)gain.GetValue(eq)!, x => { gain.SetValue(eq, x); Changed(); }, -18, 18));
                if (spec.Item1 == "MID BELL")
                    band.Children.Add(Ui.Level("Q", eq.MidQ, x => { eq.MidQ = x; Changed(); }, .1, 10, defaultValue: 1));
                bands.Children.Add(Ui.Card(band, 220));
            }
            controls.Children.Add(bands);
            controls.Children.Add(Ui.Level("OUTPUT · dB", eq.OutputGain, x => { eq.OutputGain = x; Changed(); }, -18, 18));
        }
        panel.Children.Add(Ui.Row(Ui.Text("DESK EQ", 24), Ui.Button("Reset EQ", () => { eq = new(); Changed(); BuildControls(); }), Ui.Check("Bypass", slot.Bypassed, x => { graph.Bypassed = x; graph.InvalidateVisual(); store.Edit(s => s.AllInserts.Single(v => v.Id == id).Bypassed = x, rebuild: false); })));
        panel.Children.Add(graph);
        panel.Children.Add(controls);
        BuildControls();
        panel.Children.Add(Ui.Text("Three stereo-linked bands · Double-click a slider to reset · Shift-drag for fine adjustment", 12, Theme.Muted));
        var window = Dialog("Desk EQ", panel);
        window.Width = Math.Min(780, SystemParameters.WorkArea.Width - 40);
        window.Loaded += async (_, _) => await Response();
        window.Closed += (_, _) => { closed = true; ++revision; timer.Stop(); };
        window.ShowDialog();
    }
}

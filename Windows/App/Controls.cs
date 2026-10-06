using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Text.Json.Nodes;
namespace MixingDesk;

sealed class Meter : FrameworkElement
{
    JsonNode? data;
    public Meter()
    {
        Height = 52;
        Margin = new Thickness(4, 8, 4, 8);
        ToolTip = "Click to reset held peak and overload";
        Cursor = Cursors.Hand;
    }
    public void Update(JsonNode? value)
    {
        data = value;
        InvalidateVisual();
    }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc);
        double Number(string key) => data?[key]?.GetValue<double>() ?? 0;
        double Level(double value) => Math.Clamp((20 * Math.Log10(Math.Max(value, 1e-5)) + 60) / 60, 0, 1);
        for (int i = 0; i < 2; ++i)
        {
            double y = 2 + i * 12;
            dc.DrawRoundedRectangle(Theme.Background, null, new Rect(0, y, ActualWidth, 8), 3, 3);
            double value = Number(i == 0 ? "peakL" : "peakR");
            dc.DrawRoundedRectangle(value >= .99 ? Brushes.OrangeRed : Theme.Accent, null, new Rect(0, y, ActualWidth * Level(value), 8), 3, 3);
            double held = ActualWidth * Level(Number(i == 0 ? "heldL" : "heldR"));
            dc.DrawLine(new Pen(Brushes.White, 1), new Point(held, y), new Point(held, y + 8));
        }
        double peak = Math.Max(Number("heldL"), Number("heldR")), reduction = Number("reductionDB");
        bool clipped = data?["clip"]?.GetValue<bool>() ?? false;
        string text = (peak > 1e-5 ? (20 * Math.Log10(peak)).ToString("0.0", CultureInfo.InvariantCulture) : "−∞") + " dBFS" + (clipped ? "  CLIP" : reduction > .05 ? "  LIMIT " + reduction.ToString("0.0") : "");
        dc.DrawText(new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 11, clipped ? Brushes.OrangeRed : Theme.Muted, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(0, 29));
    }
}
sealed class FineSlider : Slider
{
    Point origin; double initial; bool fine;
    protected override void OnPreviewMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0)
        {
            origin = e.GetPosition(this);
            initial = Value;
            fine = true;
            CaptureMouse();
            e.Handled = true;
        }
        else
            base.OnPreviewMouseLeftButtonDown(e);
    }
    protected override void OnPreviewMouseMove(MouseEventArgs e)
    {
        if (fine)
        {
            var p = e.GetPosition(this);
            double delta = Orientation == Orientation.Vertical ? origin.Y - p.Y : p.X - origin.X;
            Value = Math.Clamp(initial + delta * (Maximum - Minimum) / Math.Max(1, Orientation == Orientation.Vertical ? ActualHeight : ActualWidth) * .1, Minimum, Maximum);
            e.Handled = true;
        }
        else
            base.OnPreviewMouseMove(e);
    }
    protected override void OnPreviewMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        if (fine)
        {
            fine = false;
            ReleaseMouseCapture();
            e.Handled = true;
        }
        else
            base.OnPreviewMouseLeftButtonUp(e);
    }
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        fine = false;
        base.OnLostMouseCapture(e);
    }
}
static class Ui
{
    public static TextBlock Text(string text, double size = 13, Brush? color = null) => new() { Text = text, FontSize = size, Foreground = color ?? Theme.Text, Margin = new Thickness(4), TextWrapping = TextWrapping.Wrap };
    public static Button Button(string text, Action action)
    {
        var b = new Button { Content = text };
        b.Click += (_, _) => action();
        return b;
    }
    public static StackPanel Row(params UIElement[] elements)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var e in elements)
            row.Children.Add(e);
        return row;
    }
    public static Border Card(UIElement child, double width = double.NaN) => new() { Child = child, Width = width, Background = Theme.Panel, BorderBrush = Theme.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Margin = new Thickness(7), VerticalAlignment = VerticalAlignment.Top };
    public static CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Content = text, IsChecked = value, Foreground = Theme.Text, Margin = new Thickness(5), VerticalContentAlignment = VerticalAlignment.Center };
        c.Click += (_, _) => changed(c.IsChecked == true);
        return c;
    }
    public static UIElement Level(string label, double value, Action<double> changed, double min = -90, double max = 24, bool vertical = false)
    {
        string format = max - min <= 2 ? "0.###" : "0.0";
        var panel = new StackPanel();
        panel.Children.Add(Text(label, 11, Theme.Muted));
        var readout = new TextBox { Text = value.ToString(format, CultureInfo.InvariantCulture), Width = vertical ? 70 : 64, ToolTip = "Enter an exact value. Hold Shift while dragging for fine adjustment." };
        var slider = new FineSlider { Minimum = min, Maximum = max, Value = value, Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal, Height = vertical ? 160 : 25, Width = vertical ? 70 : 120, SmallChange = .1, LargeChange = 1, IsMoveToPointEnabled = false, TickFrequency = 1 };
        bool update = false;
        slider.ValueChanged += (_, _) => { if (update) return; readout.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture); changed(slider.Value); };
        void Commit()
        {
            if (double.TryParse(readout.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var x) && double.IsFinite(x) && x >= min && x <= max)
            {
                update = true;
                slider.Value = x;
                update = false;
                changed(x);
            }
            else
                readout.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture);
        }
        readout.LostKeyboardFocus += (_, _) => Commit();
        readout.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); Keyboard.ClearFocus(); e.Handled = true; } };
        panel.Children.Add(slider);
        panel.Children.Add(readout);
        return panel;
    }
}

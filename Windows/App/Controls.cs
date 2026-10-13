using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Media;
using System.Text.Json.Nodes;
namespace MixingDesk;

sealed class Meter : FrameworkElement
{
    JsonNode? data;
    public bool Compact
    {
        get; set;
    }
    public bool Vertical { get; set; }
    public Action? Reset
    {
        get; set;
    }
    public Meter()
    {
        Height = 52;
        Margin = new Thickness(4, 8, 4, 8);
        ToolTip = "Click to reset held peak and overload";
        Cursor = Cursors.Hand;
        Focusable = true;
        MouseLeftButtonUp += (_, _) => Reset?.Invoke();
        KeyDown += (_, e) => { if (e.Key is Key.Enter or Key.Space) { Reset?.Invoke(); e.Handled = true; } };
    }
    protected override AutomationPeer OnCreateAutomationPeer() => new MeterPeer(this);
    sealed class MeterPeer(Meter owner) : FrameworkElementAutomationPeer(owner), IInvokeProvider
    {
        public override object? GetPattern(PatternInterface pattern) => pattern == PatternInterface.Invoke ? this : base.GetPattern(pattern);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;
        public void Invoke() => owner.Dispatcher.BeginInvoke(() => owner.Reset?.Invoke());
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
        double verticalHeight = Math.Max(1, ActualHeight - 23);
        for (int i = 0; i < 2; ++i)
        {
            if (Vertical)
            {
                double x = i * 12, height = verticalHeight * Level(Number(i == 0 ? "peakL" : "peakR"));
                dc.DrawRoundedRectangle(Theme.Recessed, null, new Rect(x, 0, 8, verticalHeight), 2, 2);
                dc.DrawRoundedRectangle(Number(i == 0 ? "peakL" : "peakR") >= .99 ? Brushes.OrangeRed : Theme.Color("teal"), null, new Rect(x, verticalHeight - height, 8, height), 2, 2);
                double yHeld = verticalHeight * (1 - Level(Number(i == 0 ? "heldL" : "heldR")));
                dc.DrawLine(new Pen(Theme.Text, 1), new Point(x, yHeld), new Point(x + 8, yHeld));
                continue;
            }
            double y = Compact ? i * 6 : 2 + i * 12, barHeight = Compact ? 3 : 8;
            dc.DrawRoundedRectangle(Theme.Recessed, null, new Rect(0, y, ActualWidth, barHeight), 2, 2);
            double value = Number(i == 0 ? "peakL" : "peakR");
            dc.DrawRoundedRectangle(value >= .99 ? Brushes.OrangeRed : Theme.Color("teal"), null, new Rect(0, y, ActualWidth * Level(value), barHeight), 2, 2);
            double held = ActualWidth * Level(Number(i == 0 ? "heldL" : "heldR"));
            dc.DrawLine(new Pen(Theme.Text, 1), new Point(held, y), new Point(held, y + barHeight));
        }
        double peak = Math.Max(Number("heldL"), Number("heldR")), reduction = Number("reductionDB");
        bool clipped = data?["clip"]?.GetValue<bool>() ?? false;
        if (Vertical)
            foreach (int db in new[] { 0, -12, -24, -36, -48, -60 })
                dc.DrawText(new FormattedText(db.ToString(), CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 9, Theme.Muted, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(27, Math.Clamp(-db / 60.0 * verticalHeight - 5, 0, verticalHeight - 10)));
        string text = (peak > 1e-5 ? (20 * Math.Log10(peak)).ToString("0.0", CultureInfo.InvariantCulture) : "−∞") + " dBFS" + (clipped ? "  CLIP" : reduction > .05 ? "  LIMIT " + reduction.ToString("0.0") : "");
        if (Vertical && (clipped || reduction > .05))
            text = clipped ? "CLIP" : "LIMIT −" + reduction.ToString("0.0");
        dc.DrawText(new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), Compact || Vertical ? 9 : 11, clipped ? Brushes.OrangeRed : Theme.Muted, VisualTreeHelper.GetDpi(this).PixelsPerDip), new Point(0, Vertical ? verticalHeight + 5 : Compact ? 12 : 29));
    }
}
sealed class FineSlider : Slider
{
    public double DefaultValue
    {
        get; set;
    }
    Point origin; double initial; bool fine;
    protected override void OnPreviewMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            Value = Math.Clamp(DefaultValue, Minimum, Maximum);
            e.Handled = true;
        }
        else if ((Keyboard.Modifiers & ModifierKeys.Shift) != 0)
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
    public static TextBlock Text(string text, double size = 13, Brush? color = null)
    {
        var block = new TextBlock { Text = text, FontSize = size, Margin = new Thickness(4), TextWrapping = TextWrapping.Wrap };
        Theme.Bind(block, TextBlock.ForegroundProperty, color ?? Theme.Text);
        return block;
    }
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
    public static Border Card(UIElement child, double width = double.NaN)
    {
        var card = new Border { Child = child, Width = width, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(12), Margin = new Thickness(7), VerticalAlignment = VerticalAlignment.Top };
        Theme.Bind(card, Border.BackgroundProperty, Theme.Panel);
        Theme.Bind(card, Border.BorderBrushProperty, Theme.Line);
        return card;
    }
    public static Button Toggle(string text, bool value, Action<bool> changed, string label)
    {
        var button = Button(text, () => { });
        button.Padding = new Thickness(8, 2, 8, 2);
        button.FontSize = 11;
        void Refresh()
        {
            button.Background = value ? Theme.Accent : Theme.Recessed;
            button.Foreground = value ? (Theme.Dark ? Brushes.Black : Brushes.White) : Theme.Muted;
            AutomationProperties.SetName(button, label + (value ? ", on" : ", off"));
        }
        button.Click += (_, _) => { value = !value; changed(value); Refresh(); };
        button.ToolTip = label;
        Refresh();
        return button;
    }
    public static TextBox Number(double value, Action<double> changed, double min, double max, string label)
    {
        double committed = value;
        string Display(double x) => x.ToString(max - min <= 2 ? "0.###" : "0.0", CultureInfo.InvariantCulture);
        var field = new TextBox { Text = Display(value), Width = 62, FontSize = 11, Padding = new Thickness(3), ToolTip = label + $" ({min}…{max}); Enter applies, Escape cancels", HorizontalContentAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetName(field, label);
        void Commit()
        {
            string text = field.Text.Trim();
            if (text is "-inf" or "-∞")
                text = min.ToString(CultureInfo.InvariantCulture);
            if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var next) && double.IsFinite(next) && next >= min && next <= max)
            {
                if (next != committed)
                {
                    committed = next;
                    changed(next);
                }
                field.Text = Display(committed);
                field.ClearValue(Control.BorderBrushProperty);
            }
            else
            {
                field.Text = Display(committed);
                field.BorderBrush = Brushes.DarkOrange;
            }
        }
        field.LostKeyboardFocus += (_, _) => Commit();
        field.Tag = (Action<double>)(next => { committed = next; field.Text = Display(next); });
        field.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); Keyboard.ClearFocus(); e.Handled = true; } else if (e.Key == Key.Escape) { field.Text = Display(committed); field.ClearValue(Control.BorderBrushProperty); Keyboard.ClearFocus(); e.Handled = true; } };
        return field;
    }
    public static UIElement CompactLevel(string label, double value, Action<double> changed, double min, double max, Action<bool>? gesture = null, bool compact = false)
    {
        var panel = new StackPanel();
        bool updating = false;
        var slider = new FineSlider { Minimum = min, Maximum = max, Value = value, DefaultValue = 0, Height = 20, SmallChange = 1, Margin = new Thickness(3, 0, 3, 0) };
        AutomationProperties.SetName(slider, label);
        bool dragging = false;
        slider.PreviewMouseLeftButtonDown += (_, _) => { dragging = true; gesture?.Invoke(true); };
        void Finish()
        {
            if (!dragging)
                return;
            dragging = false;
            gesture?.Invoke(false);
        }
        slider.PreviewMouseLeftButtonUp += (_, _) => Finish();
        slider.LostMouseCapture += (_, _) => Finish();
        slider.Unloaded += (_, _) => Finish();
        var readout = Number(value, x => { updating = true; slider.Value = x; updating = false; changed(x); }, min, max, label);
        if (compact)
        {
            readout.Padding = new Thickness(1);
            readout.Margin = new Thickness(1);
            readout.FontSize = 10;
            slider.Height = 16;
        }
        slider.ValueChanged += (_, _) => { if (updating) return; ((Action<double>)readout.Tag!)(slider.Value); changed(slider.Value); };
        var heading = new DockPanel();
        var caption = Text(label, 9, Theme.Muted);
        heading.Children.Add(caption);
        DockPanel.SetDock(readout, Dock.Right);
        heading.Children.Add(readout);
        panel.Children.Add(heading);
        panel.Children.Add(slider);
        return panel;
    }
    public static UIElement Frequency(double value, Action<double> changed, double defaultValue)
    {
        bool updating = false;
        var slider = new FineSlider { Minimum = Math.Log10(20), Maximum = Math.Log10(20000), Value = Math.Log10(value), DefaultValue = Math.Log10(defaultValue), Width = 180, Height = 25, SmallChange = .01 };
        var number = Number(value, x => { updating = true; slider.Value = Math.Log10(x); updating = false; changed(x); }, 20, 20000, "Frequency in Hz");
        number.Width = 90;
        slider.ValueChanged += (_, _) => { if (updating) return; double hz = slider.Value == slider.DefaultValue ? defaultValue : Math.Clamp(Math.Pow(10, slider.Value), 20, 20000); ((Action<double>)number.Tag!)(hz); changed(hz); };
        var panel = new StackPanel();
        panel.Children.Add(Row(Text("Hz", 11, Theme.Muted), number));
        panel.Children.Add(slider);
        return panel;
    }
    public static CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Content = text, IsChecked = value, Foreground = Theme.Text, Margin = new Thickness(5), VerticalContentAlignment = VerticalAlignment.Center };
        Theme.Bind(c, Control.ForegroundProperty, Theme.Text);
        c.Click += (_, _) => changed(c.IsChecked == true);
        return c;
    }
    public static UIElement Level(string label, double value, Action<double> changed, double min = -90, double max = 12, bool vertical = false, double defaultValue = 0, double verticalHeight = 160)
    {
        string format = max - min <= 2 ? "0.###" : "0.0";
        var panel = new StackPanel();
        panel.Children.Add(Text(label, 11, Theme.Muted));
        var readout = new TextBox { Text = value.ToString(format, CultureInfo.InvariantCulture), Width = vertical ? 70 : 64, ToolTip = "Enter an exact value. Hold Shift while dragging for fine adjustment." };
        var slider = new FineSlider { Minimum = min, Maximum = max, Value = value, DefaultValue = defaultValue, Orientation = vertical ? Orientation.Vertical : Orientation.Horizontal, Height = vertical ? verticalHeight : 25, Width = vertical ? 70 : 180, SmallChange = max - min <= 2 ? .01 : 1, LargeChange = 1, IsMoveToPointEnabled = false, TickFrequency = 1 };
        AutomationProperties.SetName(slider, label);
        AutomationProperties.SetName(readout, label + " exact value");
        double committed = value;
        bool update = false;
        slider.ValueChanged += (_, _) => { if (update) return; committed = slider.Value; readout.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture); changed(slider.Value); };
        void Commit()
        {
            if (double.TryParse(readout.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var x) && double.IsFinite(x) && x >= min && x <= max)
            {
                update = true;
                slider.Value = x;
                update = false;
                committed = x;
                changed(x);
            }
            else
                readout.Text = slider.Value.ToString(format, CultureInfo.InvariantCulture);
        }
        readout.LostKeyboardFocus += (_, _) => Commit();
        readout.KeyDown += (_, e) => { if (e.Key == Key.Enter) { Commit(); Keyboard.ClearFocus(); e.Handled = true; } else if (e.Key == Key.Escape) { readout.Text = committed.ToString(format, CultureInfo.InvariantCulture); Keyboard.ClearFocus(); e.Handled = true; } };
        panel.Children.Add(slider);
        panel.Children.Add(readout);
        return panel;
    }
}

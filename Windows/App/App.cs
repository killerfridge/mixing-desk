using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace MixingDesk;

public sealed class App : Application
{
    [STAThread]
    public static void Main()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) || System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture != System.Runtime.InteropServices.Architecture.X64)
        {
            MessageBox.Show("Mixing Desk requires Windows 11 on an Intel/AMD x64 PC.");
            return;
        }
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) => { MessageBox.Show(e.Exception.Message, "Mixing Desk", MessageBoxButton.OK, MessageBoxImage.Error); e.Handled = true; };
        // Keep system inputs on a light surface; desk labels use explicit theme colours.
        // An implicit white TextBlock style also affects system control templates.
        foreach (var type in new[] { typeof(ComboBox), typeof(Menu), typeof(TabItem) })
        {
            var control = new Style(type);
            control.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
            control.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.WhiteSmoke));
            app.Resources[type] = control;
        }
        var button = new Style(typeof(Button));
        button.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(10, 5, 10, 5)));
        button.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(3)));
        app.Resources[typeof(Button)] = button;
        button.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
        button.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.WhiteSmoke));
        var box = new Style(typeof(TextBox));
        box.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(6)));
        box.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(3)));
        app.Resources[typeof(TextBox)] = box;
        box.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
        box.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.WhiteSmoke));
        app.Run(new MainWindow());
    }
}
static class Theme
{
    public static readonly Brush Background = new SolidColorBrush(Color.FromRgb(19, 24, 31));
    public static readonly Brush Panel = new SolidColorBrush(Color.FromRgb(29, 36, 45));
    public static readonly Brush Text = new SolidColorBrush(Color.FromRgb(230, 237, 243));
    public static readonly Brush Muted = new SolidColorBrush(Color.FromRgb(151, 165, 181));
    public static readonly Brush Accent = new SolidColorBrush(Color.FromRgb(73, 210, 178));
    public static readonly Brush Line = new SolidColorBrush(Color.FromRgb(57, 70, 84));
}

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace MixingDesk;

public sealed class App : Application
{
    public static int RunDesktop(bool smokeTest)
    {
        StartupLog.Write("Creating WPF application");
        var app = new App { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.DispatcherUnhandledException += (_, e) =>
        {
            StartupLog.Write("Unhandled UI error", e.Exception);
            e.Handled = true;
            if (smokeTest)
                app.Shutdown(1);
            else
                MessageBox.Show(e.Exception.Message + "\n\n" + StartupLog.LocationMessage, "Mixing Desk", MessageBoxButton.OK, MessageBoxImage.Error);
        };
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
        button.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
        button.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.WhiteSmoke));
        // Inserting an implicit style into application resources seals it.
        // Finish every setter before publishing the style.
        app.Resources[typeof(Button)] = button;
        var box = new Style(typeof(TextBox));
        box.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(6)));
        box.Setters.Add(new Setter(FrameworkElement.MarginProperty, new Thickness(3)));
        box.Setters.Add(new Setter(Control.ForegroundProperty, Brushes.Black));
        box.Setters.Add(new Setter(Control.BackgroundProperty, Brushes.WhiteSmoke));
        app.Resources[typeof(TextBox)] = box;
        StartupLog.Write("Creating main window");
        return app.Run(new MainWindow(smokeTest));
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

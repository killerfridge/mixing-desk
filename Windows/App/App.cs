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
        Theme.Apply();
        Theme.InstallStyles(app);
        StartupLog.Write("Creating main window");
        return app.Run(new MainWindow(smokeTest));
    }
}

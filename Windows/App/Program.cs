using System;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace MixingDesk;

static class Program
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "MessageBoxW")]
    static extern int ShowError(IntPtr owner, string text, string caption, uint type);

    [STAThread]
    public static int Main(string[] args)
    {
        bool smokeTest = args.Contains("--smoke-test");
        StartupLog.Start();
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            StartupLog.Write("Unhandled process error", e.ExceptionObject as Exception);
        try
        {
            // Windows 10 22H2 is the minimum compatibility-testing target.
            if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19045) || RuntimeInformation.ProcessArchitecture != Architecture.X64)
                throw new PlatformNotSupportedException("Mixing Desk requires Windows 10 22H2 or Windows 11 on an Intel/AMD x64 PC.");
            int result = RunDesktop(smokeTest);
            StartupLog.Write($"Application exited with code {result}");
            return result;
        }
        catch (Exception e)
        {
            StartupLog.Write("Startup failed", e);
            // A native dialog still works when WPF itself failed to initialize.
            if (!smokeTest)
                ShowError(IntPtr.Zero, "Mixing Desk could not start.\n\n" + e.Message + "\n\n" + StartupLog.LocationMessage, "Mixing Desk", 0x10);
            return 1;
        }
    }

    // Resolve WPF types only after Main's error handler and log are ready.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static int RunDesktop(bool smokeTest) => App.RunDesktop(smokeTest);
}

using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

namespace MixingDesk;

static class StartupLog
{
    static readonly object sync = new();
    static string? path;
    internal static string? DirectoryPath => path is null ? null : Path.GetDirectoryName(path);
    public static string LocationMessage => path is null ? "The startup log could not be written." : "Details saved to:\n" + path;

    public static void Start()
    {
        try
        {
            string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mixing Desk", "Logs");
            Directory.CreateDirectory(directory);
            path = Path.Combine(directory, $"startup-{Environment.ProcessId}.log");
            File.WriteAllText(path, "");
        }
        catch { path = null; }
        string version = Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown";
        Write($"Starting Mixing Desk {version}; {RuntimeInformation.OSDescription}; {RuntimeInformation.ProcessArchitecture}; .NET {Environment.Version}");
        Write("Application folder: " + AppContext.BaseDirectory);
    }

    public static void Write(string message, Exception? error = null)
    {
        // Flush each checkpoint so a native crash still leaves the last step.
        lock (sync)
        {
            try
            {
                if (path is not null)
                    File.AppendAllText(path, $"{DateTimeOffset.Now:O} {message}\n" + (error is null ? "" : error + "\n"));
            }
            catch { /* A logging failure must not prevent the mixer from opening. */ }
        }
    }
}

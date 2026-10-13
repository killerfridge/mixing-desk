using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using MixingDesk.Models;
namespace MixingDesk;

sealed partial class MainWindow
{
    // Used only by --smoke-test. DeskStore disables session writes in this mode.
    async Task CheckInterface()
    {
        store.StopPollingForSmokeTest();
        string appearance = Preferences.Current.Appearance, density = Preferences.Current.Density, bank = Preferences.Current.Bank;
        try
        {
            Preferences.Current.Bank = "All";
            Preferences.Current.Density = "Automatic";
            Width = 1280;
            Height = 950;
            var session = store.Session;
            session.Strips[0].Source.DeviceUID = "fixture:microphone";
            session.Strips[1].Source.BundleID = "fixture:music";
            session.Strips[1].Name = "Music";
            session.Strips[2].Source.BundleID = "fixture:call";
            session.Strips[0].Inserts.Add(new());
            session.SelectMonitor("fixture:headphones", 2);
            session.Routes.Add(new()
            {
                SourceID = session.Buses[1].Id,
                DestinationUID = "fixture:call-output"
            });
            session.Routes.Add(new()
            {
                SourceID = session.Buses[2].Id,
                DestinationUID = "fixture:stream-offline"
            });
            store.Devices.Add(new("fixture:microphone", "USB Audio Interface", 2, 0));
            store.Devices.Add(new("fixture:headphones", "Headphones", 0, 2));
            store.Devices.Add(new("fixture:call-output", "Call Microphone", 0, 2));
            store.Applications.Add(new("fixture:music", "Music Player"));
            store.Applications.Add(new("fixture:call", "Call App"));
            session.Validate();
            foreach (string mode in new[] { "Dark", "Light" })
            {
                Preferences.Current.Appearance = mode;
                RefreshAppearance();
                foreach (int page in new[] { 0, 1, 2, 3 })
                {
                    tabs.SelectedIndex = page;
                    Rebuild();
                    await Settle();
                    if (page == 2)
                    {
                        Click("Fit All");
                        await Settle();
                    }
                    Capture(this, mode.ToLowerInvariant() + "-" + new[] { "desk", "patching", "pipeline", "setup" }[page]);
                }
            }
            Preferences.Current.Appearance = "Dark";
            RefreshAppearance();
            tabs.SelectedIndex = 2;
            var extra = new Bus { Name = "Connection check" };
            store.Edit(s => s.Buses.Add(extra), "Test add bus");
            await Settle();
            var source = new PipelineNode("strip", store.Session.Strips[0].Id);
            var target = new PipelineNode("bus", extra.Id);
            ClickNamed("Output port: " + NodeName(source));
            ClickNamed("Input port: " + NodeName(target));
            await Settle();
            Require(PipelineGraph.Sends(store.Session, source).Any(s => s.BusID == target.Id), "Click-to-connect did not create the send.");
            store.Undo(false);
            Require(PipelineGraph.Sends(store.Session, source).All(s => s.BusID != target.Id), "Connection undo failed.");
            store.Undo(true);
            Require(PipelineGraph.Sends(store.Session, source).Any(s => s.BusID == target.Id), "Connection redo failed.");
            selectedPipelineNode = target.Key;
            selectedPipelineEdge = null;
            Rebuild();
            await Settle();
            pipelineKeys?.Invoke(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(this), 0, Key.Delete));
            Require(store.Session.Buses.All(b => b.Id != target.Id) && PipelineGraph.Sends(store.Session, source).All(s => s.BusID != target.Id), "Delete must remove the node and its cables.");
            store.Undo(false);
            Require(store.Session.Buses.Any(b => b.Id == target.Id), "Node removal undo failed.");
            var response = (await store.PluginCall("eqResponse", JsonSerializer.SerializeToNode(new EqSettings(), Session.Options)!.AsObject()))!.AsArray();
            Require(response.Count == 256 && response.All(v => Math.Abs(v!.GetValue<double>()) < 1e-8), "Default EQ response must be flat.");
            var band = (await store.PluginCall("eqResponse", JsonSerializer.SerializeToNode(new EqSettings { MidGain = 6 }, Session.Options)!.AsObject()))!.AsArray();
            Require(band.Max(v => v!.GetValue<double>()) > 5.9, "EQ response must reflect the native filter.");
            await DialogCheck(() => EqDialog(store.Session.Strips[0].Inserts[0].Id), "eq");
            Width = 800;
            Height = 520;
            tabs.SelectedIndex = 2;
            Rebuild();
            await Settle();
            Click("Fit All");
            await Settle();
            Capture(this, "compact-pipeline");
            StartupLog.Write("PASS: interface themes, desk/patching/pipeline/setup, port connection, undo/redo, delete, EQ and compact rendering");
        }
        finally { Preferences.Current.Appearance = appearance; Preferences.Current.Density = density; Preferences.Current.Bank = bank; }
    }
    static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }
    async Task Settle()
    {
        await Dispatcher.InvokeAsync(UpdateLayout, DispatcherPriority.Loaded);
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
    static IEnumerable<T> Descendants<T>(DependencyObject parent) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = VisualTreeHelper.GetChild(parent, i);
            if (child is T match)
                yield return match;
            foreach (var next in Descendants<T>(child))
                yield return next;
        }
    }
    void Click(string content) => Descendants<Button>(this).First(b => b.Content is string s && s == content).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    void ClickNamed(string name) => Descendants<Button>(this).First(b => AutomationProperties.GetName(b) == name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    static void Capture(Window window, string name)
    {
        if (StartupLog.DirectoryPath is not string directory)
            return;
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(window.ActualWidth), (int)Math.Ceiling(window.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(window);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(Path.Combine(directory, $"ui-{name}-{Environment.ProcessId}.png"));
        encoder.Save(file);
    }
    Task DialogCheck(Action open, string name)
    {
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(700) };
        Exception? failure = null;
        timer.Tick += (_, _) => { timer.Stop(); var dialog = Application.Current.Windows.Cast<Window>().LastOrDefault(w => w != this); if (dialog is null) { failure = new InvalidOperationException("Dialog did not open: " + name); return; } try { Capture(dialog, name); } catch (Exception e) { failure = e; } finally { dialog.Close(); } };
        timer.Start();
        try
        {
            open();
        }
        finally { timer.Stop(); }
        if (failure is not null)
            throw failure;
        return Task.CompletedTask;
    }
}

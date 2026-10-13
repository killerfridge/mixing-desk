# Mixing Desk for Windows

An additional Windows application sharing the Mac version's C++ engine. The Mac
SwiftUI application and its build scripts remain supported.

**Development beta: Windows 11, Intel/AMD x64, WASAPI shared audio, 48 kHz.**
Windows 10 22H2 (build 19045 or later) is also enabled for compatibility testing.
This includes build 19045.6466; 32-bit Windows and ARM64 are not targets.
This branch has not yet passed physical Windows audio or UI acceptance. Do not
treat a successful cross-build as a validated release.
The initial implementation's [validation record](VALIDATION.md) distinguishes
completed checks from those still requiring Windows.

## Build on Windows

Install the .NET 10 SDK, CMake 3.24 or newer, and Visual Studio Build Tools with
Desktop development with C++ and a current Windows SDK. From a Developer
PowerShell terminal at the repository root:

```powershell
./scripts/build-windows.ps1
```

The script builds native x64 binaries, runs the engine/Windows/model tests,
publishes the self-contained WPF application, checks that it can open and render
its main window and initialize the native host, and produces a ZIP in
`build/windows-release`. It downloads pinned nlohmann/json and libsamplerate
sources at build time. No runtime network access or Microsoft account is needed.

Extract the entire ZIP, then open `MixingDesk.exe`. Keep the native DLL and
scanner executable beside it. These development builds are unsigned. Windows
reputation protection or your organisation's policy may block them.

The ZIP includes native checks that require no SDK. In PowerShell, from the
extracted folder, run `./Diagnostics/Test-Native.ps1`. They exercise the shared
engine, session/clock code and a synthetic VST3 effect without opening hardware
audio endpoints. They do not replace the physical audio checks below.

`./Diagnostics/Test-Startup.ps1` checks desktop startup using a fresh session,
then closes its test instance without starting audio or loading your saved
session. The build script runs this check unless `-SkipTests` is specified.
If normal launch fails, startup errors display a dialog and write details under
`%LOCALAPPDATA%\Mixing Desk\Logs\startup-<process-id>.log`. These local logs
include the app version, Windows version and startup checkpoints; nothing is
uploaded automatically. Failures before .NET starts still require the Windows
Application event log.

## First mix

1. Choose headphones or an interface under Monitor. Set the Microphone source
   in Source / Settings, including its mono/stereo input channels.
2. Select applications after they have opened an audio stream. Direct capture
   leaves their original playback running, so new direct-capture assignments
   start with the Monitor send off. Stop/start capture after an app restarts.
3. To control application monitoring entirely through the mixer, route the app's
   playback to an installed virtual cable in the app or Windows Volume Mixer.
   Select that cable's recording endpoint as an input, or direct-capture the app
   while its ordinary output goes to the unmonitored cable.
4. For calls, patch Call to a **different** virtual cable's playback endpoint.
   Select its recording endpoint as the call app's microphone. Leave Call Return
   excluded in the Call bus settings. Use another cable for an independent Stream
   mix. Never feed a bus back into the cable supplying that same mix.
5. Use Desk → Scan VST3 Effects before adding installed Windows x64 plugins.
   Reload unavailable inserts after a scan. Mac Audio Units remain unavailable;
   their settings are retained. Bypass an unavailable insert to hear dry audio.

[VB-CABLE](https://vb-audio.com/Cable/) is a separately installed example. The app
neither redistributes nor installs its driver. Additional independent cable pairs
may require separate downloads/licences from the supplier. The app also accepts
other WASAPI capture and playback endpoints.

Direct application capture on Windows 10 remains a physical-PC test item.
[Microsoft's sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)
documents build 20348 or later, while
[OBS supports application capture on Windows 10 2004 and later](https://obsproject.com/kb/application-audio-capture-guide).
Mixing Desk attempts activation on 22H2 and reports any failure for that source.
If capture fails, route the application to a virtual cable and select its
recording endpoint as the source. Other input devices can still be used.

## Controls and compatibility

Desk, Patching and Pipeline edit one session. Pipeline supports draggable nodes,
drag or click port connections, compatible-target highlighting, individual cable
editing, downstream/mix-minus tracing, block controls, Fit All, arrangement, pan,
zoom and routing undo. Patching includes the channel/bus matrix. Select a block
or cable and press Delete to remove it; the Monitor bus is protected. Escape
cancels a pending cable. Drag empty canvas to pan; Ctrl+wheel zooms around the
pointer and Shift+wheel pans horizontally. The Connections menu also supports
keyboard routing and cable editing.

Choose **View → Appearance → System / Light / Dark** and **View → Desk layout**.
Channels/Buses/All banks and expandable sends keep small windows usable. File
includes session naming, preset save/load, and portable JSON import/export.
Presets are stored in `%LOCALAPPDATA%\Mixing Desk\Presets`.

Double-click a slider to restore its default. Hold Shift while dragging a level
for fine adjustment; type exact values in readouts (Enter applies, Escape cancels).
Click meters to clear held peaks. Ctrl+Shift+L clears solos. Ctrl+Z/Y undo/redo
routing, Ctrl+O opens a session, and Ctrl+Shift+S exports one.

Desk EQ displays the shared native engine's frequency response with logarithmic
frequency controls, bypass and reset. The output protection indicator opens
destination/channel details. See the [Mac/Windows feature comparison](PARITY.md)
for remaining platform differences.

Sessions autosave under `%LOCALAPPDATA%\Mixing Desk\session.json`, with a backup
of the previous save. Imported Mac bindings remain offline until reassigned.
VST3 state uses the existing property-list container; cross-platform restoration
still depends on the vendor shipping a compatible plugin and state format.
Presentation metadata is not sent to the audio host.

Audio starts explicitly. Closing the window keeps the system tray mixer active;
Quit stops it. A lost audio endpoint stops the engine and requires explicit
restart. There is no automatic fallback to another output. Sources missing at
startup stay offline and silent until the next start.

The selected monitor supplies the clock. Other endpoints have bounded buffers
and adaptive sample-rate correction. Buffer settings are requests, not promises
about driver periods; inspect the status tooltip for actual endpoint buffering.
The existing 2 ms protection delay is only one part of end-to-end latency.

Deferred: ARM64, 32-bit x86, ASIO, custom named virtual devices, vendor plugin
windows, VST2, instruments/MIDI/sidechains, parallel-path delay compensation and
plugin processing isolation. In-process plugins can crash or hang the mixer.

## Verification and release gate

Automated checks cover the shared engine, Windows session compiler, independent
clock drift at ±1000 ppm, scoped undo, legacy defaults, EQ, property-list parsing,
and opaque unavailable-plugin preservation. Assertions stay enabled in release
test builds. Windows CI builds and packages an artifact; it does not publish a
release or install audio drivers.

Before release, on physical x64 Windows 11 and Windows 10 22H2 PCs:

- Verify launch on a clean account without the SDK or Visual Studio installed.
- Verify source selection, channel mapping, start/stop, all three views, keyboard
  access, 100/150/200% display scaling, minimum window size and system tray Quit.
- Verify a real 60-minute microphone + application + headphones + virtual output
  run. Record device/driver versions, actual periods, measured loopback latency,
  discontinuities and audible results; synthetic drift tests are not this test.
- Verify independent call/stream mixes, transitive mix-minus, and no doubled
  application monitoring or cable feedback in the documented setup.
- Test app exit/restart, unplug/replug, unsupported/unavailable endpoints, a
  default-device change and sleep/resume. Audio must never move to speakers.
- Test Windows VST3 mono/stereo effects, scan crashes/timeouts, state restoration,
  bypass, parameter edits, removal/reload and Mac session round trips.
- Check the shared Mac build and existing regression suite before merging.

The code lives in `Windows/`; the platform-neutral audio algorithms remain in
`Sources/DeskAudio`. The C ABI in `Windows/Native/DeskWindows.h` is versioned and
uses owned UTF-8 response buffers. All calls for a host are serialized on a
dedicated control thread; the native audio thread never enters .NET.

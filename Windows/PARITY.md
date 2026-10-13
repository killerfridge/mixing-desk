# Windows and macOS feature comparison

The Windows application shares the Mac audio engine and version-1 session format.
The October 2026 interface update brings the shared editing workflow to WPF.
It does not turn Mac-only drivers or Audio Units into Windows components.

| Feature | Windows |
| --- | --- |
| Desk, Patching, Pipeline, Setup | Available; one shared session |
| Pipeline blocks and connection ports | Drag blocks; drag or click ports; keyboard Connect to menu |
| Cable inspection and edits | Individual level/pre-post/channel editors; apply/cancel/disconnect |
| Graph visibility | Source colours, off/excluded dashed cables, mix-minus badges, downstream tracing |
| Navigation | Pan, pointer-centred Ctrl+wheel zoom, touch pinch/translation, zoom buttons, Fit All, topological Auto Arrange |
| Block controls | Live fader, trim, mute/solo, ordered effects, meters, source/settings menus |
| Graph editing | Add/remove channel, bus and output; protected Monitor bus; routing undo/redo |
| Layout persistence | Same session position/output metadata; layout does not reconfigure audio |
| Patching | Channel/bus matrix plus independently mapped output patches and route gains |
| Appearance | Saved System/Light/Dark and Automatic/Compact/Comfortable choices |
| Desk controls | Colour, role, polarity, protection, fine/reset sliders, exact entry, channel ordering, sends and banks |
| Sessions/presets | Autosave, JSON import/export, naming, preset save/load, opaque unavailable AU preservation |
| EQ and VST3 | Four ordered inserts; native EQ response graph/reset/bypass; searchable VST3 browser and parameter editor |
| Protection/meters | Held peaks, per-owner/all resets, clipping/limiting distinction, physical output-group detail |
| Tray | Show, start/stop, clear solos, reset meters, quit |

## Platform differences

- Windows uses WASAPI shared endpoints and separately installed virtual cables.
  The Mac HAL driver and in-app creation of named virtual audio devices do not
  run on Windows. Installing/managing a Windows virtual driver is a separate
  driver project. Existing cable inputs/outputs are usable throughout the app.
- Windows VST3 effects use the parameter editor, as Mac VST3 effects do. Mac AUv2
  plugins, their vendor editors and `.aupreset` imports are unavailable on Windows;
  saved AU settings remain intact for a later Mac session.
- Windows direct application capture leaves ordinary application playback running.
  New application channels therefore start with their Monitor sends off. Virtual
  cables give the mixer control of monitoring without duplicate playback.
- Keyboard modifiers, touch/trackpad event delivery and host audio/device details
  follow Windows conventions. Ctrl+wheel is available where a trackpad does not
  deliver native touch gestures.
- No ASIO, ARM64, 32-bit x86, VST2, instruments/MIDI, parallel-path delay
  compensation or plugin process isolation has been added.

## Verification

Model tests cover topology, cycle rejection, transitive mix-minus, source identity,
solo trace restrictions, presentation metadata isolation and removal/undo. The
published-app check exercises theme/tab rendering, click-to-connect, deletion,
undo/redo and the native EQ response. It uses a temporary in-memory desk and
does not overwrite the user's session or start audio. CI saves screenshots as
startup diagnostics. Actual mouse dragging, Windows display scaling, touch and
long-running hardware audio still need physical-PC acceptance.

# Mixing Desk

A local, native macOS mixer for USB audio hardware, application audio, BlackHole, and named virtual devices. SwiftUI presents the desk and patch matrix; a C++ engine processes audio; an Objective-C++ Core Audio backend manages hardware clocks, aggregate devices, and process taps.

## Build and open

Requirements: Apple Silicon, macOS 14.4 or later, and Apple's Command Line Tools. Full Xcode is required only for the Xcode workflow and XCTest runner. The MIT-licensed Steinberg VST3 interface headers are vendored; no dependency downloads or accounts are required to build. Plugin vendors may require their own licenses.

```sh
./scripts/build.sh
open 'build/Mixing Desk.app'
```

The build produces an ad-hoc signed application and `build/MixingDeskAudio.driver`. Set `DESK_SIGN_IDENTITY` to use a local signing identity instead. Use a stable app location/signature for consistent macOS privacy permissions across builds.

Alternatively open `MixingDesk.xcodeproj`, select the **MixingDesk** scheme, and build. The project has app, audio engine, models, HAL driver, and model-test targets. Regenerate it after adding source files with `python3 scripts/generate-project.py`. It uses no Xcode project generator dependency.

## First session

1. In **Setup**, choose **Quad Cortex** for headphones and clock master. The desk runs at 48 kHz; start with 128 samples. Choosing this device creates a Monitor bus output patch to channels 1/2, which you can replace in Patching if your hardware routing differs.
2. Open each channel's source selector. Bind Microphone to **RØDE VideoMic GO II**, channel 1. Bind Guitar to the actual wet or dry USB channels in your Quad Cortex preset. The desk deliberately does not guess the guitar channel pair or modify the Quad Cortex preset.
3. For software, select **Application** and a running audio application, or select an audio device such as BlackHole. Applications appear after creating an audio stream. Their selected process outputs are muted while the tap runs to avoid duplicate playback.
4. Choose **Mixer Monitoring** or **Direct Guitar**. In Mixer mode, disable the parallel direct guitar headphone path on the Quad Cortex. In Direct Guitar mode, keep that hardware path active: strips with the Guitar role are omitted only from the desk's headphone mix.
5. Start Audio and grant the requested microphone/system-audio access. Closing the window leaves the menu-bar mixer running. Stop Audio or Quit ends mixing. Opening a saved session stops audio until you explicitly start it.

The desk never selects a replacement headphone device automatically. If the chosen output disappears, routes are retained and audio stops until that same device returns.

## Virtual devices

Install the driver once:

```sh
sudo ./scripts/install-driver.sh
```

Reboot when convenient to load it. The installer verifies the built signature, preserves any previous driver, and does not restart Core Audio or interrupt other applications. To disable it later, run `sudo ./scripts/uninstall-driver.sh` and reboot.

For development updates, `sudo ./scripts/install-driver.sh --restart-audio` installs the driver and restarts Core Audio instead of requiring an immediate Mac restart. **This interrupts audio in all applications.** Reopen affected audio apps if needed. If the new driver still is not reported, reboot to load it.

In **Virtual Devices**, create **Desk Call** and **Desk Stream** as stereo devices, and **Desk Recording** as a 16-channel device. Creation/renaming after installation needs no administrator access or reinstall. Up to 16 devices may be active at once, each with 1–64 channels. Channel counts are immutable; create a replacement device when changing them. Devices with external clients cannot be removed.

Each device has two independent directions:

| In another application | In Mixing Desk |
| --- | --- |
| Microphone/input: Desk Call | Patch the Call bus to Desk Call output channels 1/2 |
| Speaker/output: Desk Call | Select Desk Call as a channel-strip source |
| Recording/input: Desk Recording | Patch direct strips to distinct recording channels |

The driver uses hidden companion endpoints for the mixer. It does not automatically loop its public output into its public input. The device remains present across app quits/reboots and returns silence without fresh mixer audio.

For a virtual call return, associate the source with its application in Channel Settings and choose that strip in the Call bus's **Exclude Return** selector. Do not also capture the same application through a process tap. Exclusions follow source identity through indirect bus routes. This prevents internal return feedback; routes through external applications/hardware still need sensible configuration.

## Routing and controls

- Mono strips use equal-power pan; stereo strips use balance. Trim, fader, pan, polarity, mute, send levels, bus gain, and output route gains are smoothed.
- Mute affects all channel sends and direct outputs. A pre-fader send is after trim/inserts/mute/pan and independent of the fader. Default sends are post-fader.
- Direct outputs are after trim/inserts/mute and optionally the fader, **before pan**. A single-channel direct patch takes the strip's left/mono channel; a stereo patch carries both. A single-channel bus patch selects its left channel; it does not silently sum stereo to mono.
- Solo auditions only the Monitor output, even if that bus also feeds another bus. It does not alter recording, call, or stream feeds.
- The patch matrix controls strip-to-bus and bus-to-bus connections. Bus sends are post-master. Cycles are rejected. Right-click a connection for its pre/post setting or level; strip sends also have continuous sliders on the desk.
- Output patches connect buses or direct strips to device channels. Multiple patches into one destination are summed. Use appropriate levels; the first version has clipping meters rather than a limiter.
- Double-click any slider to restore its default: faders, trim, sends, and output patch gains return to 0 dB; pan/balance returns to centre. EQ sliders return to their initial frequency, gain, or Q. Fader keyboard accessibility actions adjust it in 1 dB steps. Clear the meters' latched clipping indicators with the reset button.
- Sessions and presets are versioned JSON. The last valid session is autosaved under `~/Library/Application Support/Mixing Desk/`. Device UIDs and application bundle IDs survive restart; missing bindings remain offline.

## Window sizes

**Automatic** layout adapts to the window size. Smaller windows use shorter strips, expandable **Sends**, and separate **Channels / Buses / All** banks. Switch the layout menu to **Compact** or **Comfortable** to override this. The minimum window is 800 × 520 points; controls remain scrollable at very small sizes. Patching scrolls its matrix horizontally without pushing output-route controls beyond the window. Setup stacks its panels vertically in compact mode.

## VST3 and AUv2 plugins

1. Install and activate the **Apple Silicon VST3 or AUv2** version using the plugin vendor's installer. AUv2 effects are discovered through macOS registration. VST3 effects are discovered recursively in `~/Library/Audio/Plug-Ins/VST3` and `/Library/Audio/Plug-Ins/VST3`; the user copy takes precedence when both contain the same effect. The host does not install plugin bundles.
2. Open a channel or output bus's **Inserts** panel, then choose **Add Insert → VST3 / AUv2 Plugin…**. Filter by format or search by name/manufacturer, choose **Add**, then **Open Parameter Editor** (VST3) or **Open Plugin Editor** (AUv2). **Rescan** refreshes both formats. VST3 effects use the desk’s parameter editor; AUv2 uses the vendor’s native editor with a generic fallback. Editor windows scroll when their controls exceed the screen.
3. Mix Desk EQ, VST3, and AUv2 effects in up to four ordered slots. Bypass transitions over 5 ms. Editor settings are captured while open and on close, export, preset save, or quit. Plugin format, identity, name, settings, order, and bypass survive session reloads. Existing AU sessions continue to load. **Import AU Preset…** accepts an `.aupreset` belonging to an AUv2 effect; VST3 settings are saved in the session. **Reload** retries initialization after a license or installation change.

Channel effects run after trim/polarity and before fader/pan/sends/direct outputs. On a bus, plugins process the complete mix **after call-return exclusions and Monitor audition, before the master fader**. A bus containing either plugin format must have no sends to other buses. This prevents nonlinear processors such as amp simulators and compressors from defeating downstream mix-minus. Channel effects and output buses cover separate headphone, Zoom, OBS, and recording processing.

Missing or failed plugins retain their saved settings and silence their active wet output; explicit bypass provides dry audio. Inserts show load/render errors. An unavailable source remains silent even if its plugin generates noise. A successful load cannot prove a vendor license is active: some plugins return silence without an error when unlicensed.

Plugin-reported latency appears per insert. The footer adds the longest active channel and output-bus chains to the Core Audio estimate, conservatively including chains that may not share a route. **Parallel-path delay compensation is not implemented.** VST3 latency changes are applied between callbacks; a plugin requesting a new IO layout or component reload displays a message to reload the insert.

Loaded VST3 libraries remain resident until quit to preserve vendor shared services. After replacing or updating an existing VST3 bundle, restart the app; Rescan discovers newly installed effects.

Vendor VST3 windows and their custom preset/file browsers are not enabled in this release: installed Neural DSP and UADx native windows failed asynchronous teardown checks. Their effects can be controlled through the VST3 parameter editor; use AUv2 when you need the vendor interface.

VST3 discovery runs each bundle in a separate helper process with a 15-second timeout; failed scanners are skipped. Processing for both formats, and AUv2 discovery, run in the mixer process, so a crashing or hanging active plugin can still affect the app. The host supports 48 kHz Float32 mono/stereo audio effects. AUv3, VST2, instruments, external MIDI/sidechains, transport automation, and audio-processing isolation are not supported. Vendor DSP controls its own real-time behavior.

Compatibility results are recorded in the [validation notes](docs/VALIDATION.md), including the native VST3 window limitation.

Neural DSP and native Universal Audio UADx effects use their existing licenses. UAD-2 effects require compatible UA hardware. Steinberg's interface source and MIT notice are in `Sources/DeskAudio/VST3SDK`; the license is also included in built apps.

## Built-in EQ

Click **Add Insert**, then choose **Desk EQ** on any channel or bus. The insert editor provides a low shelf, a parametric mid band, and a high shelf, with adjustable frequencies from 20 Hz to 20 kHz and ±18 dB gain. The mid band has adjustable Q (0.1–10); output gain is also ±18 dB. The response graph uses the same coefficients as the audio engine.

A new EQ is flat: default frequencies are 120 Hz, 1 kHz, and 8 kHz, with mid Q 1 and every gain at 0 dB. Double-click a slider to reset that parameter, or choose **Reset EQ** to restore the whole curve. **Bypass** preserves the settings. Up to four inserts may be added, reordered, and removed per channel or bus; settings, order, and bypass are saved with the session.

Channel inserts run after trim/polarity and before mute, pan, and fader, so they affect all sends and direct recording outputs. Bus inserts run before the bus master fader. Parameter and bypass changes crossfade over 5 ms. The EQ adds no buffering latency; like other minimum-phase filters, it changes phase around the affected frequencies. Strong boosts may clip downstream outputs; watch the meters and use output gain to compensate.

## Engine and extensibility

The audio callback uses preallocated planar Float32 scratch buffers, lock-free configuration publication, atomic metering, and no heap allocation. A serial control queue performs Core Audio configuration independently of the UI. Private aggregates run from the selected hardware clock, with drift correction explicitly set and verified on the aggregate's other subdevices. Setup shows the verified clock members. They continue processing when captured applications are silent.

The engine supports 64 strips, 16 buses, 512 aggregate channels per direction, 512 output patches, and buffers up to 4096 frames. GUI buffer choices cover 32–1024 frames; hardware may support a subset. Reconfiguration can produce a brief silence. Reported latency is an estimate from Core Audio, not a measured round-trip guarantee.

`InsertProcessor` defines preparation, real-time processing/reset, bypass, state serialization, and latency reporting. The built-in EQ is the first implementation, with ordered insert chains and versioned state. Its biquad filters use the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) equations, prepared outside the render callback. Bus EQ retains separate filter history for each source origin so indirect call-return exclusions cannot leak a filter tail. This works because EQ is linear. Plugin buses process a complete, already-excluded mix and cannot feed downstream buses; lifting this restriction will require complete mix variants for every exclusion path.

The shared plugin rack prepares AUv2 and VST3 instances outside IO and retires them only after the render thread acknowledges a newer configuration. VST3 lifecycle, state, and editor calls run on the main thread; parameter values cross into IO through preallocated queues and lock-free atomics. Editors retain their instance independently. VST3 sessions store stable class IDs, processor/controller state, and pending editor parameter values rather than absolute bundle paths. Unsupported formats or malformed states are rejected; missing identities retain their saved settings. Existing version-1 sessions remain compatible.

The driver configuration interface is versioned (`DriverProtocol.h`); its audio rings keep sample timestamps and separate directions. Stale/missing frames and a stopped counterpart produce silence. Device names and IDs are stored through the HAL host's persistence API. BlackHole is accessed as an ordinary device; its code is not bundled.

## Tests

`./scripts/vst3-test.sh` builds a small VST3 test bundle inside `build/` without installing it. It verifies isolated discovery (including a scanner that terminates unexpectedly), instrument filtering, mono/stereo negotiation, 32–4096-frame processing, smoothed bypass, generic editor parameter transfer, processor output parameters, latency changes, saved processor/controller state including pending edits, malformed/missing-plugin silence, concurrent snapshots, and editor lifetime after insert removal. These tests use synthetic buffers and no audio hardware. Run `./scripts/vst3-test.sh --list` to enumerate installed effects, or pass a listed 32-character class ID to test a real plugin, including parameter editor creation and teardown. Installed-plugin checks require macOS plugin access and the vendor license.


`./scripts/audio-unit-test.sh` checks the real AU adapter using Apple's AUHipass on both mono and stereo sources, without hardware IO. These AU checks also run in `scripts/test.sh`. `--list` prints effect identifiers; pass an identifier such as `61756d66:4e474a58:4e445350` to test an installed effect, adding `--mono` to check a mono source. Run outside a restricted development sandbox so macOS can enumerate Audio Units. These checks use synthetic samples and do not play or record microphone audio. They cover channel negotiation through initialization, rendering, bypass, saved state, the snapshot/publication race, and missing-plugin silence. Third-party checks require a working license.

```sh
./scripts/test.sh
./scripts/test.sh --soak
```

The test script runs engine tests, a driver test host, the synthetic VST3 suite, and standalone Swift session tests. With full Xcode it also runs XCTest. `--soak` processes 60 minutes of audio **offline, faster than real time** with 16 stereo strips and four buses; it does not test physical USB drift.

See [validation notes](docs/VALIDATION.md) for measured results and the remaining hardware/application checks. The driver test host exercises the real driver interface without installing code into the system audio service.

To enumerate live hardware or exercise a silent five-second hardware aggregate:

```sh
./scripts/probe.sh
./scripts/probe.sh --silent-io
```

The silent test requires the Quad Cortex and VideoMic. It sends zeros to every output and never saves or transmits microphone samples. Run it locally with macOS audio access; sandboxed development processes may see no devices.

After installing driver build 2 or newer, `./scripts/live-driver-test.sh` exercises a temporary 16-channel device through the actual HAL: separate directions, two readers, channel isolation, active-IO deletion protection, silence after stop, rename, and deletion. It generates test samples only inside that virtual device. `--inspect` only checks the installed driver; `--cleanup-tests` removes idle devices created by this test (UID prefix `local.mixingdesk.test.`). Device cleanup failures fail the test.

`./scripts/live-driver-test.sh --aggregate <temporary-device-uid>` tests the real mixer with the Quad Cortex, RØDE, and a test virtual device: 16 synthetic strips, four buses, reversed direct recording channels, and silence after engine stop. The existing test device is retained and every physical output remains silent.

`./scripts/live-driver-test.sh --eq-test 60` creates a temporary 16-channel device and verifies the native session-to-DSP path with 16 channel EQs and four bus EQs, expected recording gains, and silence after stop. All physical outputs remain silent and the temporary device is removed on completion.

`./scripts/live-driver-test.sh --blackhole-soak 900` runs a 15-minute waveform continuity check with BlackHole 16ch, Quad Cortex as clock, the RØDE, 16 source strips, four buses, and a temporary virtual recording device. Reserve BlackHole channels 15/16 for its quiet synthetic tones; the test leaves channels 1/2 alone and sends silence to all physical outputs. It checks native BlackHole input, aggregate input, engine output, and virtual recording input, reporting discontinuities, missing samples, and callback overruns every 30 seconds. The test-only inspection hook is excluded from app builds. Failure or interruption cleans up its temporary device. This tests sample continuity, not audible listening or converter latency.

For a controlled application-tap smoke test, run `./scripts/build-test-source.sh`, launch `build/DeskTestSource.app/Contents/MacOS/DeskTestSource` in one terminal, and run `./scripts/probe.sh --tap-io` in another within 30 seconds. The source only produces silence and exits automatically.

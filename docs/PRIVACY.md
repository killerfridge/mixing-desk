# Privacy

Mixing Desk processes audio locally. The app has no account system, telemetry SDK, network client, automatic updater, audio-file recorder, or audio upload path. This statement is based on review of the application, audio engine, driver, and package dependencies for the 0.5.0 beta; it does not describe macOS or third-party plugins.

Microphone permission permits access to device inputs. macOS also controls capture of other applications’ audio. Only assigned application sources are tapped. Routing a bus or strip to a virtual device or hardware output makes audio available to the receiving application/device, which may record or transmit it under its own settings and policies.

AUv2 and VST3 plugins execute in the app process. They can have their own network, licensing, storage, and privacy behaviour. The app does not install plugins, change their licences, or include them in downloads.

Sessions and presets are JSON under `~/Library/Application Support/Mixing Desk/`, or locations you explicitly export to. They can contain device UIDs, application bundle IDs, user-provided names, and opaque plugin state (which can contain paths or other private data). Interface preferences are stored in macOS UserDefaults. The driver stores virtual-device names/identities through Core Audio’s host persistence API. Removing the app or driver preserves that data.

No diagnostics are automatically sent to the maintainer. Review any files before attaching them to GitHub issues. GitHub, macOS Gatekeeper, and plugin vendors operate under their own privacy policies.

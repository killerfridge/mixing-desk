# Installing the experimental beta

Requirements: an Apple Silicon Mac running macOS 14.4 or later, an administrator account for the installer, and an output supporting 48 kHz. Intel Macs are not supported.

## Download and approve

Download only from [Mixing Desk Releases](https://github.com/killerfridge/mixing-desk/releases). The combined installer is `MixingDesk-<version>-arm64.pkg`; the separate removal tool is `Remove-MixingDesk-Audio-<version>.pkg`. `BUILD.json` records source/build details. `SHA256SUMS.txt` allows checking downloaded bytes, but is not an Apple identity signature.

The app and driver have ad-hoc signatures; the installer packages are unsigned and none of these files is Apple-notarized. After trying to open a package or the app, macOS may offer **Open Anyway** in System Settings → Privacy & Security. Use that option only when you trust the source; follow [Apple’s current instructions](https://support.apple.com/en-ie/102445). This is not an instruction to override a malware warning. Managed-device policy can prohibit approval.

Do not disable Gatekeeper, change global security settings, or remove quarantine attributes. If the documented approval does not work, stop and report your macOS version and exact message. Fresh-Mac installation and HAL loading are pending until the release checklist records them as passed.

## Install

1. Export your session as a backup if upgrading. Choose **Quit Mixing Desk**, including from the menu bar, and close apps using its virtual devices before changing the driver.
2. Open the combined installer. Mixing Desk is required and installs in `/Applications/Mixing Desk.app`.
3. Leave **Mixing Desk Audio (optional)** unchecked for app-only installation. Existing driver files are then left in place. Select it for named virtual microphone/recording devices.
4. Installing or replacing the driver requires a restart to load it. The installer does not restart Core Audio, interrupt it with a service-kill command, or launch Mixing Desk as root. Save work before accepting Installer’s restart prompt.
5. Open the app from Applications and follow the setup guide. Driver status is shown under Virtual Devices.

Keep the app at the installed location. An update may require renewed macOS approval and microphone/system-audio permissions because ad-hoc signatures do not establish a stable developer identity.

## Update or return to a previous app version

Updates are manual. Read release notes, export a session backup, quit the app, then run the new installer. Leave the driver option unchecked unless a driver change is needed. Existing version-1 sessions and virtual-device IDs are preserved. Keep your previous installer; older apps may not understand features added by newer releases, so restore a matching exported session if reverting.

The installer retains a copy of a replaced driver under `/Library/Application Support/Mixing Desk/Driver Backups/`, outside the active HAL directory. Backups are restricted to administrators. Prefer reinstalling a known compatible release over manually moving driver files.

## Remove

To remove virtual audio, quit the mixer and close apps using its devices. Run **Remove-MixingDesk-Audio-<version>.pkg** and restart. This moves the driver out of the HAL directory into the backup location; it does not remove the app, saved sessions, presets, or persistent virtual-device configuration. A reinstall restores access to that configuration.

To remove only the app, quit it and move it from Applications to the Trash. The optional driver requires its own removal package. Session data remains under `~/Library/Application Support/Mixing Desk/` until you choose to delete it.

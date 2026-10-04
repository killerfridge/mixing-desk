# Release acceptance and publication

Target: `v0.5.0-beta.1`. **Public binary publication is blocked until every required item below has evidence.** GitHub draft assets are preparation, not an accepted release. Keep exact artifact checksums with every test result; rebuilds invalidate affected acceptance evidence.

## Automated / local

- [ ] Clean tag matches `release/version.txt`, app version/build, and source revision in BUILD.json.
- [ ] Source/history audit reviewed; third-party licences and attribution present.
- [ ] GitHub CI passes on the configured minimum/current macOS generations, including full Xcode build/tests.
- [ ] Engine, driver host, AU/VST3 synthetic suites, models, and offline soak pass.
- [ ] App/driver architecture, minimum OS, signatures, permissions, resources, package payloads, checksums, and default installer choices pass verification.
- [ ] Screenshots and installation instructions reflect the release.

## Clean Macs — required before public binaries

Use browser-downloaded artifacts carrying ordinary download quarantine, on Macs not used to develop this app. Test macOS 14.4 and the current supported macOS. Record exact OS/build, hardware, date, artifact SHA-256, approval screens, and result.

- [ ] App-only install, default driver deselection, manual package/app approval, first launch.
- [ ] Optional driver install and successful HAL loading after a full reboot.
- [ ] Upgrade from the previous development app/driver; exported and autosaved sessions retained.
- [ ] Driver replacement leaves a usable backup outside HAL and asks for restart.
- [ ] Driver removal, full reboot, reinstall, retained virtual-device IDs/names/channel counts.
- [ ] Running app prevents replacement; no root app launch or automatic Core Audio restart.
- [ ] Privacy approval after an ad-hoc update; denial and recovery instructions verified.

If manual approval cannot load the app or HAL driver, do not publish binaries or suggest global security workarounds. Fix packaging and repeat these checks; if no supported path exists, keep source-only distribution until the distribution approach is revisited.

## Audio and independent first use

At least two friends must follow the instructions without developer assistance, on two audio configurations including a non-Quad-Cortex interface. Record observations with their consent; do not commit names or private recordings.

- [ ] Tester A: installation, setup, first mix, call/stream routing.
- [ ] Tester B: different interface, same tasks, instruction corrections applied.
- [ ] Actual application audio captured; call return excluded; simultaneous streaming and multichannel recording do not bleed between routes.
- [ ] Permission denial, app quit/relaunch, unplug/reconnect, clock/output loss, sleep/wake, buffer changes; saved routes retained and no automatic speaker fallback.
- [ ] Real 60-minute mixed workload; record overrun counts and waveform/listening results. Offline soak does not satisfy this item.
- [ ] Populated virtual-device configuration persists through a full Mac reboot.
- [ ] No unresolved blocking crashes, saved-session loss, or unintended-output defects.

## Publish the GitHub beta

1. Commit reviewed changes and pass PR checks. Set the configured release version, app build, and release notes together.
2. Tag that commit with the configured `v<version>` and push it. The release workflow rebuilds and checks the exact tag, then creates a **draft prerelease** with installer/removal packages, BUILD.json, INSTALL.md, and checksums.
3. Download the draft artifacts as an authorized maintainer and distribute those exact bytes to the agreed acceptance testers. Do not publish merely to obtain a downloadable test build; a private file transfer can carry the same bytes, and browser-download/quarantine acceptance must still be tested.
4. Record all acceptance evidence for those checksums. Review the complete checklist and publish the existing draft only when all required checks pass. If bytes change, re-run affected checks.

## Later general distribution

After the beta has passed the same gates and blocking reported defects are fixed, prepare a stable version without the `-beta.N` suffix and repeat the release process. Add a simple download/documentation page linking to the same GitHub assets. Retain previous versions and manual update instructions. Do not describe unnotarized builds as Apple-approved. Paid signing, automatic updates, Intel/Windows, and Mac App Store work require a separate change of scope.

## Evidence log

Append dated results with exact versions, checksums, and links to CI runs or local logs. Unchecked items remain pending; do not infer a pass from an unrelated development-machine test. Current implementation validation is recorded separately in VALIDATION.md.

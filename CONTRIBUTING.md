# Contributing

This is a best-effort community project. Small, reproducible bug reports and focused pull requests are welcome; no response time or commercial support is promised. Discuss substantial new features in an issue before building them.

## Build

Use Apple Silicon and macOS 14.4+. Install Apple Command Line Tools; full Xcode is needed only for the Xcode workflow and XCTest.

```sh
./scripts/build.sh
./scripts/test.sh --soak
```

Builds produce an ad-hoc-signed app and HAL driver in `build/`. No third-party plugins need to be installed for the synthetic regression suite. Vendor compatibility checks require the vendor’s own installation and licence.

Open `MixingDesk.xcodeproj` for the Xcode workflow. After adding sources or resource references, regenerate it with `python3 scripts/generate-project.py`. Do not hand-edit generated project settings. To recreate the icon, run `swift -module-cache-path .build/ModuleCache scripts/generate-icon.swift build/MixingDesk.iconset`, then `iconutil -c icns build/MixingDesk.iconset -o Resources/MixingDesk.icns`.

## Verify changes

Run meaningful regression tests for the changed behaviour. `scripts/test.sh` covers the engine, a driver test host, synthetic AU/VST3 adapters, and session models; with full Xcode it also runs XCTest. `--soak` is an offline workload equivalent to 60 minutes, not physical-device endurance testing.

```sh
python3 scripts/audit-source.py
python3 scripts/package-release.py
```

Packaging verifies arm64/minimum OS, ad-hoc signatures, bundled licences, installer payloads, and default choices without installing anything. Outputs are under `build/release/<version>/`. Local builds record whether their checkout was dirty. `--verify-tag` requires a clean checkout at the exact tag from `release/version.txt`; use it for actual release assets.

The driver installer changes system audio software. Use it only for intentional local driver development, quit the mixer first, and prefer a restart. The explicit developer-only `--restart-audio` option interrupts audio in other apps. See the [technical reference](docs/REFERENCE.md) for hardware probes and plugin checks.

## Reports and pull requests

Include macOS/app/driver versions, interface and plugin details, exact reproduction steps, expected behaviour, and whether the issue reproduces with plugins bypassed. Review logs and sessions for private identifiers and plugin state before sharing. Do not attach audio recordings or licensing information unless needed and yours to share.

Changes must preserve saved-session compatibility and explicit output selection. Avoid real-time allocations, locks, or filesystem work in render callbacks. Keep source code under the project’s MIT licence and retain third-party notices. Do not upload third-party plugin binaries or licences.

## Releases

Read [the release checklist](docs/RELEASE_CHECKLIST.md). CI checks supported macOS generations; release automation creates **drafts only**. Only publish the exact tested artifacts after recording clean-Mac, hardware, and friend acceptance results. Signing/notarization and automatic updates are outside this beta.

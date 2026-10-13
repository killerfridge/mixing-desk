# Windows port validation — updated 13 October 2026

Implementation branch: `codex/windows-x64`, based on `d9ca210`.
Validation hosts: Apple Silicon macOS and GitHub's `windows-2025` runner.
The existing Mac application, driver and
shared engine sources are unchanged by this port.

| Check | Result |
| --- | --- |
| Existing Mac app and HAL driver build (`scripts/build.sh`) | Passed |
| Shared engine and driver regression checks | Passed |
| Existing Apple Audio Unit fixture, stereo and mono | Passed outside the filesystem sandbox |
| Existing Mac VST3 fixture and DeskModelChecks | Passed |
| CMake portable `DeskEngineTests` and `DeskWindowsTests` | Passed with release assertions enabled |
| .NET session, routing history, EQ and binary/XML state checks | Passed |
| WPF self-contained `win-x64` publish | Passed |
| Windows native DLL, scanner and native test executables | Cross-compiled and linked as PE x86-64; exports and imports inspected |
| Native tests executing on Windows, MSVC build, Windows CI | Passed at `39e59e0`; see the CI record below |
| Windows 10 22H2 (including build 19045.6466) | User reports launch, audio and patching working after `42f994b`; full acceptance checklist still outstanding |
| Automated Windows UI rendering and editing | Passed at `39e59e0`: both themes, all tabs, port connections, delete/undo/redo, native EQ and compact window |
| Physical dragging/touch, display scaling, virtual cables and real VST3 vendors | Physical-PC acceptance still required |

The local ZIP uses .NET SDK 10.0.401, CMake 4.4.3, Clang/LLD 21.1.5 and
llvm-mingw UCRT headers/libraries (20260922). It includes the self-contained
.NET runtime and dependency notices. The normal Windows build script uses
Visual Studio's x64 toolchain.

[Windows CI run 38374708881](https://github.com/killerfridge/mixing-desk/actions/runs/38374708881)
passed at `39e59e0`, including MSVC compilation, native and model tests,
self-contained WPF publishing, desktop startup/editing checks and ZIP artifact
upload. Rendered screenshots were reviewed for the desk, patching, pipeline,
compact window and EQ. This runner does not validate Windows 10, real mouse/touch
gestures or physical audio devices.

The 12 October compatibility change lowers the startup minimum from Windows 11
to Windows 10 22H2 (build 19045) and replaces the Windows-11-only application
capture error with activation diagnostics and a virtual-cable suggestion.
The user's reported build is 19045.6466. Its .NET Runtime event log identified
an unhandled `SetterBaseCollection` exception in `App.Main`: button and text-box
styles were modified after insertion into application resources sealed them.
All setters now precede insertion. Early managed startup exceptions are logged
and shown in a native dialog, including failures before the main window exists.

The build now includes a desktop startup check against the published app. It
renders the main window, initializes the native host with a fresh session, and
quits without starting audio. A failed launch prevents packaging. This closes
a gap in the original checks, which published WPF but never launched it.

On 13 October the user confirmed that audio and patching work on the test PC.
This is not a measured latency or long-duration acceptance result. The subsequent
interface update adds model checks for pipeline topology and tracing, and expands
the Windows smoke test to render each tab in both themes, connect through ports,
delete/undo nodes and verify the native EQ response. See [PARITY.md](PARITY.md).

The native diagnostics in the ZIP can run on Windows without installing an SDK.
They include an isolated synthetic VST3 scanner/lifecycle fixture. The synthetic
clock test covers ±1000 ppm drift and queue recovery; it does not demonstrate
real-device latency or a 60-minute hardware run.

Use the physical-PC acceptance checklist in the Windows setup guide before
calling this a tested Windows beta or publishing a release. No Windows release
has been published, and no Windows driver has been installed by this work.

# Windows port validation — 7 October 2026

Implementation branch: `codex/windows-x64`, based on `d9ca210`.
Validation host: Apple Silicon macOS. The existing Mac application, driver and
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
| Native tests executing on Windows, MSVC build, Windows CI | Not yet run |
| Windows UI, physical devices, virtual cables and real VST3 vendors | Not yet tested |

The local ZIP uses .NET SDK 10.0.401, CMake 4.4.3, Clang/LLD 21.1.5 and
llvm-mingw UCRT headers/libraries (20260922). It includes the self-contained
.NET runtime and dependency notices. The normal Windows build script uses
Visual Studio's x64 toolchain; that build path still needs a Windows execution.

The native diagnostics in the ZIP can run on Windows without installing an SDK.
They include an isolated synthetic VST3 scanner/lifecycle fixture. The synthetic
clock test covers ±1000 ppm drift and queue recovery; it does not demonstrate
real-device latency or a 60-minute hardware run.

Use the physical-PC acceptance checklist in the Windows setup guide before
calling this a tested Windows beta or publishing a release. No Windows release
has been published, and no Windows driver has been installed by this work.

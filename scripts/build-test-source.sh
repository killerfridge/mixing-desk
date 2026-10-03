#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build/DeskTestSource.app/Contents/MacOS
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks Tests/TestAudioSource.mm -framework AppKit -framework CoreAudio -o build/DeskTestSource.app/Contents/MacOS/DeskTestSource
python3 - <<'PY'
import plistlib
from pathlib import Path
p=Path('build/DeskTestSource.app/Contents/Info.plist')
p.write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.mixingdesk.testsource','CFBundleName':'Desk Silent Test Source','CFBundleExecutable':'DeskTestSource','CFBundlePackageType':'APPL','LSUIElement':True,'NSMicrophoneUsageDescription':'Run a silent local audio integration test.'}))
PY
codesign --force --sign - build/DeskTestSource.app

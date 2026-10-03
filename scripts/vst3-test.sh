#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build/vst3-fixtures/DeskTest.vst3/Contents/MacOS
sdk="Sources/DeskAudio/VST3SDK"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -mmacosx-version-min=14.4 -bundle Tests/VST3Fixture.mm Sources/DeskAudio/VST3Identifiers.cpp "$sdk/pluginterfaces/base/funknown.cpp" -I "$sdk" -framework Foundation -framework AppKit -o build/vst3-fixtures/DeskTest.vst3/Contents/MacOS/DeskTest
cat > build/vst3-fixtures/DeskTest.vst3/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>DeskTest</string><key>CFBundleIdentifier</key><string>local.mixingdesk.vst3test</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>
PLIST
codesign --force --sign - build/vst3-fixtures/DeskTest.vst3
mkdir -p build/vst3-fixtures/Unavailable.vst3/Contents/MacOS
xcrun clang++ -std=c++20 -O2 -mmacosx-version-min=14.4 -bundle Tests/VST3ScanFailure.cpp -o build/vst3-fixtures/Unavailable.vst3/Contents/MacOS/DeskTest
cp build/vst3-fixtures/DeskTest.vst3/Contents/Info.plist build/vst3-fixtures/Unavailable.vst3/Contents/Info.plist
codesign --force --sign - build/vst3-fixtures/Unavailable.vst3
xcrun clang++ -std=c++20 -O2 -DMD_PLUGIN_TESTS -fobjc-arc -fblocks -mmacosx-version-min=14.4 Sources/DeskAudio/AudioUnitHost.mm Sources/DeskAudio/PluginHost.mm Sources/DeskAudio/VST3Host.mm Sources/DeskAudio/VST3Identifiers.cpp "$sdk/pluginterfaces/base/funknown.cpp" Tests/VST3Tests.mm -I "$sdk" -framework Foundation -framework AudioToolbox -framework AudioUnit -framework CoreAudioKit -framework AppKit -o build/vst3-tests
if [[ $# -eq 0 ]]; then
    MD_VST3_TEST_PATH="$desk_root/build/vst3-fixtures" build/vst3-tests
else
    build/vst3-tests "$@"
fi

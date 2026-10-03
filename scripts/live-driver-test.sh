#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build
xcrun clang++ -std=c++20 -O2 -DMD_AUDIO_PROBE -fobjc-arc -fblocks -mmacosx-version-min=14.4 Tests/LiveDriverProbe.mm Sources/DeskAudio/AudioHost.mm Sources/DeskAudio/AudioUnitHost.mm Sources/DeskAudio/PluginHost.mm Sources/DeskAudio/VST3Host.mm Sources/DeskAudio/VST3Identifiers.cpp Sources/DeskAudio/VST3SDK/pluginterfaces/base/funknown.cpp -I Sources/DeskAudio/VST3SDK Sources/DeskAudio/Engine.cpp -framework Foundation -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreAudioKit -framework AppKit -o build/live-driver-probe
build/live-driver-probe "$@"

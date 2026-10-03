#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -mmacosx-version-min=14.4 Sources/DeskAudio/AudioUnitHost.mm Sources/DeskAudio/PluginHost.mm Sources/DeskAudio/VST3Host.mm Sources/DeskAudio/VST3Identifiers.cpp Sources/DeskAudio/VST3SDK/pluginterfaces/base/funknown.cpp -I Sources/DeskAudio/VST3SDK Tests/AudioUnitTests.mm -framework Foundation -framework AudioToolbox -framework AudioUnit -framework CoreAudioKit -framework AppKit -o build/audio-unit-tests
if [[ $# -eq 0 ]]; then
    build/audio-unit-tests
    build/audio-unit-tests 61756678:68706173:6170706c --mono
else
    build/audio-unit-tests "$@"
fi

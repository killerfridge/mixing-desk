#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -mmacosx-version-min=14.4 Sources/DeskAudio/AudioUnitHost.mm Sources/DeskAudio/PluginHost.mm Sources/DeskAudio/VST3Host.mm Sources/DeskAudio/VST3Identifiers.cpp Sources/DeskAudio/VST3SDK/pluginterfaces/base/funknown.cpp -I Sources/DeskAudio/VST3SDK Tests/AudioUnitEditorTests.mm -framework Foundation -framework AudioToolbox -framework AudioUnit -framework CoreAudioKit -framework AppKit -o build/audio-unit-editor-tests
if [[ $# -eq 0 ]]; then
    for desk_id in 61756678:46743736:5374746c 61756678:54623631:5374746c 61756678:42733161:5374746c; do
        printf 'Testing %s\n' "$desk_id"
        build/audio-unit-editor-tests "$desk_id"
    done
else
    build/audio-unit-editor-tests "$@"
fi

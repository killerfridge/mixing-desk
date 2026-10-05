#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
export CLANG_MODULE_CACHE_PATH="$desk_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$desk_root/.build/ModuleCache"
desk_bin="$(swift build -c release --arch arm64 --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
desk_sources=()
for desk_source in Sources/MixingDesk/*.swift; do
    [[ "$desk_source" == */MixingDeskApp.swift ]] || desk_sources+=("$desk_source")
done
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.4 -module-cache-path .build/ModuleCache \
    -I "$desk_bin/Modules" -I "$desk_bin" -I Sources/DeskAudio/include \
    "${desk_sources[@]}" Tests/PipelineFixture.swift Tests/PipelineUIIdentityChecks.swift \
    "$desk_bin"/DeskModels.build/*.o "$desk_bin"/DeskAudio.build/*.o "$desk_bin"/DeskAudio.build/VST3SDK/pluginterfaces/base/*.o \
    -lc++ -framework CoreAudio -framework AudioToolbox -framework AudioUnit -framework CoreAudioKit -framework AppKit -o build/pipeline-checks
build/pipeline-checks "$@"

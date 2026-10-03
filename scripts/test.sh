#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$desk_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$desk_root/.build/ModuleCache"
xcrun clang++ -std=c++20 -O2 -pthread Sources/DeskAudio/Engine.cpp Tests/EngineTests.cpp -o build/engine-tests
build/engine-tests "$@"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks Driver/Driver.mm Tests/DriverTests.mm -framework Foundation -framework CoreAudio -o build/driver-tests
build/driver-tests
./scripts/audio-unit-test.sh
./scripts/vst3-test.sh
swift run --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security DeskModelChecks
if [[ -d "$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" ]]; then
    swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
else
    printf 'XCTest unavailable in Command Line Tools; equivalent standalone model checks ran above.\n'
fi

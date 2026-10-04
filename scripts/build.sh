#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$desk_root"
mkdir -p build .build/ModuleCache
export CLANG_MODULE_CACHE_PATH="$desk_root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$desk_root/.build/ModuleCache"
export MACOSX_DEPLOYMENT_TARGET=14.4
swift build -c release --arch arm64 --product MixingDesk --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security
desk_binary_dir="$(swift build -c release --arch arm64 --show-bin-path --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)"
desk_app="$desk_root/build/Mixing Desk.app"
# Recreate only generated bundles so old resources cannot leak into releases.
rm -rf "$desk_app" "$desk_root/build/MixingDeskAudio.driver"
mkdir -p "$desk_app/Contents/MacOS" "$desk_app/Contents/Resources"
cp "$desk_binary_dir/MixingDesk" "$desk_app/Contents/MacOS/MixingDesk"
cp Resources/Info.plist "$desk_app/Contents/Info.plist"
cp Sources/DeskAudio/VST3SDK/pluginterfaces/LICENSE.txt "$desk_app/Contents/Resources/VST3-LICENSE.txt"
cp LICENSE "$desk_app/Contents/Resources/LICENSE.txt"
cp Resources/MixingDesk.icns "$desk_app/Contents/Resources/"
codesign --force --sign "${DESK_SIGN_IDENTITY:--}" "$desk_app"
desk_driver="$desk_root/build/MixingDeskAudio.driver"
mkdir -p "$desk_driver/Contents/MacOS"
xcrun clang++ -arch arm64 -std=c++20 -O2 -fobjc-arc -fblocks -mmacosx-version-min=14.4 -bundle Driver/Driver.mm -framework Foundation -framework CoreAudio -o "$desk_driver/Contents/MacOS/MixingDeskAudio"
cp Driver/Info.plist "$desk_driver/Contents/Info.plist"
mkdir -p "$desk_driver/Contents/Resources"
cp LICENSE "$desk_driver/Contents/Resources/LICENSE.txt"
codesign --force --sign "${DESK_SIGN_IDENTITY:--}" "$desk_driver"
printf 'Built application: %s\nBuilt driver: %s\n' "$desk_app" "$desk_driver"

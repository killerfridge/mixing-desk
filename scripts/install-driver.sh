#!/bin/bash
set -euo pipefail
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
desk_source="$desk_root/build/MixingDeskAudio.driver"
desk_destination="/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver"
desk_restart_audio=false
if [[ "$#" -gt 0 ]]; then
    if [[ "$#" -ne 1 || "$1" != "--restart-audio" ]]; then printf 'Usage: %s [--restart-audio]\n' "$0" >&2; exit 2; fi
    desk_restart_audio=true
fi
if [[ "$EUID" -ne 0 ]]; then printf 'Run this installer with sudo after building the project.\n' >&2; exit 1; fi
if [[ ! -f "$desk_source/Contents/MacOS/MixingDeskAudio" ]]; then printf 'Build the driver with scripts/build.sh first.\n' >&2; exit 1; fi
codesign --verify --strict "$desk_source"
if [[ -e "$desk_destination" ]]; then
    desk_backup="/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.previous-$(date +%Y%m%d-%H%M%S)"
    mv "$desk_destination" "$desk_backup"
    printf 'Previous driver backed up at %s\n' "$desk_backup"
fi
ditto "$desk_source" "$desk_destination"
chown -R root:wheel "$desk_destination"
chmod -R go-w "$desk_destination"
if [[ "$desk_restart_audio" == true ]]; then
    printf 'Installed Mixing Desk Audio. Restarting Core Audio; current audio sessions will be interrupted.\n'
    if /usr/bin/killall -TERM coreaudiod; then
        printf 'macOS will restart Core Audio automatically. Reopen audio applications if needed.\nIf the new driver build is not reported, reboot to finish loading it.\n'
    else
        printf 'The driver is installed, but Core Audio could not be restarted. Reboot to load it.\n' >&2
        exit 1
    fi
else
    printf 'Installed Mixing Desk Audio. Reboot when convenient to load the driver.\nThis installer did not restart Core Audio or interrupt current audio sessions.\n'
fi

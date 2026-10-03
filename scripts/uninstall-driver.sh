#!/bin/bash
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then printf 'Run this uninstaller with sudo.\n' >&2; exit 1; fi
desk_driver="/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver"
if [[ -d "$desk_driver" ]]; then
    desk_backup="/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.removed-$(date +%Y%m%d-%H%M%S)"
    mv "$desk_driver" "$desk_backup"
    printf 'Driver disabled; backup retained at %s\n' "$desk_backup"
fi
printf 'Reboot when convenient to unload the driver. Saved desk sessions are preserved.\n'

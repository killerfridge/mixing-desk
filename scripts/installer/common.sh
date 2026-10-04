#!/bin/bash
set -euo pipefail

desk_driver="/Library/Audio/Plug-Ins/HAL/MixingDeskAudio.driver"
desk_backups="/Library/Application Support/Mixing Desk/Driver Backups"

desk_check_install() {
    if [[ "${3:-/}" != / ]]; then
        echo 'Install Mixing Desk on the running macOS startup volume.' >&2; exit 1
    fi
    if /usr/bin/pgrep -x MixingDesk >/dev/null; then
        echo 'Quit Mixing Desk from its menu before installing or removing components. Closing its window does not quit it.' >&2; exit 1
    fi
    for desk_path in /Applications '/Applications/Mixing Desk.app' /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL "$desk_driver" '/Library/Application Support' '/Library/Application Support/Mixing Desk' "$desk_backups"; do
        if [[ -L "$desk_path" ]]; then echo "Refusing a symbolic-link installation path: $desk_path" >&2; exit 1; fi
    done
}

desk_backup_driver() {
    [[ -d "$desk_driver" ]] || return 0
    umask 077
    /bin/mkdir -p "$desk_backups"
    /usr/sbin/chown root:wheel '/Library/Application Support/Mixing Desk' "$desk_backups"
    /bin/chmod 700 '/Library/Application Support/Mixing Desk' "$desk_backups"
    local desk_backup
    desk_backup="$(/usr/bin/mktemp -d "$desk_backups/driver-$(/bin/date +%Y%m%d-%H%M%S)-XXXXXX")"
    if [[ "$1" == remove ]]; then
        /bin/mv "$desk_driver" "$desk_backup/MixingDeskAudio.driver"
    else
        /usr/bin/ditto "$desk_driver" "$desk_backup/MixingDeskAudio.driver"
    fi
    echo "Previous driver retained at $desk_backup"
}

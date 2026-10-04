#!/bin/bash
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then printf 'Run this uninstaller with sudo.\n' >&2; exit 1; fi
desk_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$desk_root/scripts/installer/common.sh"
desk_check_install
desk_backup_driver remove
printf 'Reboot when convenient to unload the driver. Saved desk sessions are preserved.\n'

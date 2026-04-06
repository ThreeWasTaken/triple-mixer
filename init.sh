#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${TRIPLE_MIXER_CONF:-$SCRIPT_DIR/triple-mixer.conf}"

if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

export TRAY_POLL_INTERVAL_MS="${TRAY_POLL_INTERVAL_MS:-200}"

pkill -f "$SCRIPT_DIR/events.sh" 2>/dev/null || true
pkill -f "$SCRIPT_DIR/tray.py" 2>/dev/null || true

"$SCRIPT_DIR/triple-mixer.sh" sync-master >/dev/null 2>&1 || true

nohup "$SCRIPT_DIR/events.sh" >/dev/null 2>&1 &
nohup python3 "$SCRIPT_DIR/tray.py" >/dev/null 2>&1 &

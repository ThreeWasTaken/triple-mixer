#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${TRIPLE_MIXER_CONF:-$SCRIPT_DIR/triple-mixer.conf}"

# Valeurs par défaut de secours
GAME_SINK="tm-game"
VOICE_SINK="tm-voice"

VOICE_MATCHES=(
  "WEBRTC VoiceEngine"
)

IGNORE_APP_MATCHES=()

DEFAULT_MASTER=100
DEFAULT_VOICE=100
DEFAULT_GAME=100
DEFAULT_STEP=5

TRAY_POLL_INTERVAL_MS=200

PACTL_BIN="pactl"
WPCTL_BIN="wpctl"

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/triple-mixer"
STATE_FILE="$STATE_DIR/state"

# Surcharge locale
if [[ -f "$CONF_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONF_FILE"
fi

mkdir -p "$STATE_DIR"

clamp() {
    local n="${1:-0}"
    [[ "$n" =~ ^-?[0-9]+([.][0-9]+)?$ ]] || n=0
    n="${n%.*}"
    (( n < 0 )) && n=0
    (( n > 100 )) && n=100
    printf '%d\n' "$n"
}

pactl_cmd() {
    "$PACTL_BIN" "$@"
}

wpctl_cmd() {
    "$WPCTL_BIN" "$@"
}

matches_any() {
    local text="${1:-}"
    shift || true

    local pat
    for pat in "$@"; do
        [[ -n "$pat" ]] || continue
        [[ "$text" == *"$pat"* ]] && return 0
    done

    return 1
}

is_voice_app() {
    local app="${1:-}"
    matches_any "$app" "${VOICE_MATCHES[@]}"
}

is_ignored_app() {
    local app="${1:-}"
    matches_any "$app" "${IGNORE_APP_MATCHES[@]}"
}

init_state() {
    [[ -f "$STATE_FILE" ]] && return

    cat > "$STATE_FILE" <<EOF
MASTER=$DEFAULT_MASTER
VOICE=$DEFAULT_VOICE
GAME=$DEFAULT_GAME
STEP=$DEFAULT_STEP
EOF
}

load_state() {
    init_state

    # shellcheck disable=SC1090
    source "$STATE_FILE"

    MASTER="$(clamp "${MASTER:-$DEFAULT_MASTER}")"
    VOICE="$(clamp "${VOICE:-$DEFAULT_VOICE}")"
    GAME="$(clamp "${GAME:-$DEFAULT_GAME}")"
    STEP="$(clamp "${STEP:-$DEFAULT_STEP}")"
}

save_state() {
    local tmp
    tmp="$(mktemp)"

    cat > "$tmp" <<EOF
MASTER=$MASTER
VOICE=$VOICE
GAME=$GAME
STEP=$STEP
EOF

    mv "$tmp" "$STATE_FILE"
}

group_var() {
    case "${1:-}" in
        master) printf 'MASTER\n' ;;
        voice)  printf 'VOICE\n' ;;
        game)   printf 'GAME\n' ;;
        *)
            printf 'Erreur: groupe invalide: %s\n' "${1:-}" >&2
            exit 1
            ;;
    esac
}

get_group() {
    local var
    var="$(group_var "$1")"
    printf '%s\n' "${!var}"
}

set_group_value() {
    local var value
    var="$(group_var "$1")"
    value="$(clamp "$2")"
    printf -v "$var" '%d' "$value"
}

print_text() {
    printf 'master=%s voice=%s game=%s step=%s\n' \
        "$MASTER" "$VOICE" "$GAME" "$STEP"
}

print_json() {
    printf '{"master":%s,"voice":%s,"game":%s,"step":%s}\n' \
        "$MASTER" "$VOICE" "$GAME" "$STEP"
}

volume_float_to_percent() {
    local v="${1:-0}"
    awk -v v="$v" 'BEGIN {
        n = int((v * 100) + 0.5)
        if (n < 0) n = 0
        if (n > 100) n = 100
        print n
    }'
}

get_master_from_system() {
    local out num percent

    out="$(wpctl_cmd get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null || true)"
    num="$(awk '/Volume:/ {print $2}' <<<"$out")"
    [[ -n "${num:-}" ]] || return 1

    percent="$(volume_float_to_percent "$num")"
    printf '%s\n' "$(clamp "$percent")"
}

sync_master_from_system() {
    local percent

    percent="$(get_master_from_system)" || return 1

    # Recharger l'état courant avant d'écrire, pour ne pas écraser
    # VOICE/GAME avec des valeurs obsolètes.
    load_state
    MASTER="$percent"
    save_state
    printf '%s\n' "$MASTER"
}

list_sink_inputs_full() {
    pactl_cmd list sink-inputs 2>/dev/null | awk '
        BEGIN {
            id = ""
            app = ""
            vol = ""
        }

        /^Sink Input #[0-9]+/ {
            if (id != "") {
                print id "|" app "|" vol
            }
            id = $3
            gsub("#", "", id)
            app = ""
            vol = ""
            next
        }

        /application.name = / {
            line = $0
            sub(/.*application.name = "/, "", line)
            sub(/".*/, "", line)
            app = line
            next
        }

        /Volume: front-left:/ && vol == "" {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+%$/) {
                    gsub("%", "", $i)
                    vol = $i
                    break
                }
            }
            next
        }

        END {
            if (id != "") {
                print id "|" app "|" vol
            }
        }
    '
}

apply_voice_absolute() {
    local line id app rest

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        id="${line%%|*}"
        rest="${line#*|}"
        app="${rest%%|*}"

        if is_ignored_app "$app"; then
            continue
        fi

        if is_voice_app "$app"; then
            pactl_cmd set-sink-input-volume "$id" "${VOICE}%" >/dev/null 2>&1 || true
        fi
    done < <(list_sink_inputs_full)
}

apply_game_delta() {
    local delta="${1:-0}"
    local line id app vol rest new

    [[ "$delta" =~ ^-?[0-9]+$ ]] || delta=0
    (( delta == 0 )) && return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        id="${line%%|*}"
        rest="${line#*|}"
        app="${rest%%|*}"
        vol="${line##*|}"

        [[ -n "$vol" ]] || continue

        if is_ignored_app "$app"; then
            continue
        fi

        if ! is_voice_app "$app"; then
            new=$(( vol + delta ))
            new="$(clamp "$new")"
            pactl_cmd set-sink-input-volume "$id" "${new}%" >/dev/null 2>&1 || true
        fi
    done < <(list_sink_inputs_full)
}

normalize_game() {
    local line id app rest

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        id="${line%%|*}"
        rest="${line#*|}"
        app="${rest%%|*}"

        if is_ignored_app "$app"; then
            continue
        fi

        if ! is_voice_app "$app"; then
            pactl_cmd set-sink-input-volume "$id" "${GAME}%" >/dev/null 2>&1 || true
        fi
    done < <(list_sink_inputs_full)
}

list_streams() {
    local line id rest app vol group

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue

        id="${line%%|*}"
        rest="${line#*|}"
        app="${rest%%|*}"
        vol="${line##*|}"

        if is_ignored_app "$app"; then
            continue
        fi

        if is_voice_app "$app"; then
            group="voice"
        else
            group="game"
        fi

        printf '%s\t%s\t%s\t%s\n' "$id" "$group" "$vol" "$app"
    done < <(list_sink_inputs_full)
}

events_loop() {
    pactl_cmd subscribe | while read -r line; do
        case "$line" in
            *"on sink-input "*|*"on server "*)
                sync_master_from_system >/dev/null 2>&1 || true
                ;;
        esac
    done
}

cmd_set() {
    local group="$1"
    local value="$2"

    case "$group" in
        voice)
            set_group_value voice "$value"
            save_state
            apply_voice_absolute
            get_group voice
            ;;
        game)
            local old_game new_game delta
            old_game="$GAME"
            new_game="$(clamp "$value")"
            delta=$(( new_game - old_game ))
            GAME="$new_game"
            save_state
            apply_game_delta "$delta"
            get_group game
            ;;
        *)
            printf 'Erreur: groupe non modifiable: %s\n' "$group" >&2
            exit 1
            ;;
    esac
}

cmd_up() {
    local group="$1"
    local step="$2"

    case "$group" in
        voice)
            VOICE="$(clamp "$(( VOICE + step ))")"
            save_state
            apply_voice_absolute
            get_group voice
            ;;
        game)
            GAME="$(clamp "$(( GAME + step ))")"
            save_state
            apply_game_delta "$step"
            get_group game
            ;;
        *)
            printf 'Erreur: groupe non modifiable: %s\n' "$group" >&2
            exit 1
            ;;
    esac
}

cmd_down() {
    local group="$1"
    local step="$2"

    case "$group" in
        voice)
            VOICE="$(clamp "$(( VOICE - step ))")"
            save_state
            apply_voice_absolute
            get_group voice
            ;;
        game)
            GAME="$(clamp "$(( GAME - step ))")"
            save_state
            apply_game_delta "-$step"
            get_group game
            ;;
        *)
            printf 'Erreur: groupe non modifiable: %s\n' "$group" >&2
            exit 1
            ;;
    esac
}

usage() {
    cat <<'EOF'
Usage:
  triple-mixer.sh print
  triple-mixer.sh json
  triple-mixer.sh get <master|voice|game>
  triple-mixer.sh set <voice|game> <0-100>
  triple-mixer.sh up <voice|game> [step]
  triple-mixer.sh down <voice|game> [step]
  triple-mixer.sh step
  triple-mixer.sh step <0-100>
  triple-mixer.sh apply-voice
  triple-mixer.sh sync-master
  triple-mixer.sh normalize-game
  triple-mixer.sh list-streams
  triple-mixer.sh events
EOF
}

main() {
    load_state

    case "${1:-}" in
        print)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            sync_master_from_system >/dev/null 2>&1 || true
            print_text
            ;;
        json)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            sync_master_from_system >/dev/null 2>&1 || true
            print_json
            ;;
        get)
            [[ $# -eq 2 ]] || { usage >&2; exit 1; }

            if [[ "$2" == "master" ]]; then
                sync_master_from_system >/dev/null 2>&1 || true
            fi

            get_group "$2"
            ;;
        set)
            [[ $# -eq 3 ]] || { usage >&2; exit 1; }
            cmd_set "$2" "$3"
            ;;
        up)
            [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 1; }
            step="$(clamp "${3:-$STEP}")"
            cmd_up "$2" "$step"
            ;;
        down)
            [[ $# -ge 2 && $# -le 3 ]] || { usage >&2; exit 1; }
            step="$(clamp "${3:-$STEP}")"
            cmd_down "$2" "$step"
            ;;
        step)
            if [[ $# -eq 1 ]]; then
                printf '%s\n' "$STEP"
            elif [[ $# -eq 2 ]]; then
                STEP="$(clamp "$2")"
                save_state
                printf '%s\n' "$STEP"
            else
                usage >&2
                exit 1
            fi
            ;;
        apply-voice)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            apply_voice_absolute
            ;;
        sync-master)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            sync_master_from_system
            ;;
        normalize-game)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            normalize_game
            ;;
        list-streams)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            list_streams
            ;;
        events)
            [[ $# -eq 1 ]] || { usage >&2; exit 1; }
            events_loop
            ;;
        -h|--help|help|"")
            usage
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"

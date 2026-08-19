#!/usr/bin/env bash
# Shared runtime helpers, installed to /usr/lib/vstos/vstos-lib.sh.
#
# Sourced by every vstos-* command and by the systemd units' ExecStart wrappers.
# It holds the two pieces of logic that must not be duplicated: reading the
# configuration, and deciding which sound card is the console.
#
# shellcheck shell=bash

VSTOS_CONF="${VSTOS_CONF:-/etc/vstos/vstos.conf}"

# Overridable so the resolver can be pointed at a fixture and tested without a
# sound card present. Nothing else in the system sets these.
VSTOS_ASOUND_CARDS="${VSTOS_ASOUND_CARDS:-/proc/asound/cards}"
VSTOS_ASOUND_DIR="${VSTOS_ASOUND_DIR:-/proc/asound}"

vstos_log()  { printf 'vstos: %s\n' "$*" >&2; }
vstos_warn() { printf 'vstos: warning: %s\n' "$*" >&2; }
vstos_die()  { printf 'vstos: error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Defaults duplicated from vstos.conf.default so that a truncated or missing
# config file degrades to a working system rather than to an empty variable
# silently becoming an empty command-line argument.
# shellcheck disable=SC2034  # these are the function's whole purpose: set for callers
vstos_load_conf() {
    AUDIO_DEVICE_MATCH="WING"
    AUDIO_DEVICE=""
    AUDIO_DEVICE_FALLBACK=0
    SAMPLE_RATE=48000
    PERIOD=128
    NPERIODS=3
    JACK_RT_PRIORITY=80
    MIDI_BRIDGE=1
    UI_MODE=auto
    INSERT_CHANNEL=1
    CARLA_PROJECT="/var/lib/vstos/projects/default.carxp"
    OSC_ENABLED=1
    OSC_PORT=22752
    CPU_GOVERNOR=performance
    AUDIO_USER=audio-op

    if [ -r "$VSTOS_CONF" ]; then
        # shellcheck disable=SC1090
        . "$VSTOS_CONF"
    else
        vstos_warn "$VSTOS_CONF not readable; using built-in defaults"
    fi

    vstos_validate_conf
}

# Catch the values that would otherwise turn into a confusing failure several
# layers down - jackd exiting with a usage message, or Xorg being started with a
# negative priority.
vstos_validate_conf() {
    case "$SAMPLE_RATE" in
        44100|48000) ;;
        *) vstos_die "SAMPLE_RATE=$SAMPLE_RATE: the WING clocks at 44100 or 48000" ;;
    esac
    case "$PERIOD" in
        16|32|64|128|256|512|1024|2048) ;;
        *) vstos_die "PERIOD=$PERIOD is not a power of two between 16 and 2048" ;;
    esac
    case "$NPERIODS" in
        2|3|4) ;;
        *) vstos_die "NPERIODS=$NPERIODS: USB audio needs 2, 3 or 4 (3 is right for the WING)" ;;
    esac
    if ! [ "$JACK_RT_PRIORITY" -ge 1 ] 2>/dev/null || [ "$JACK_RT_PRIORITY" -gt 94 ]; then
        vstos_die "JACK_RT_PRIORITY=$JACK_RT_PRIORITY is outside 1..94"
    fi
    case "$UI_MODE" in
        auto|kiosk|headless) ;;
        *) vstos_die "UI_MODE=$UI_MODE is not auto, kiosk or headless" ;;
    esac
    # The WING presents 48 USB channels each way; anything outside that cannot be
    # patched and would leave the rack silently unconnected.
    if ! [ "$INSERT_CHANNEL" -ge 1 ] 2>/dev/null || [ "$INSERT_CHANNEL" -gt 48 ]; then
        vstos_die "INSERT_CHANNEL=$INSERT_CHANNEL is outside the console's 1..48 USB channels"
    fi
}

# ---------------------------------------------------------------------------
# Sound card resolution
# ---------------------------------------------------------------------------

_vstos_trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    printf '%s' "$v"
}

# /proc/asound/cards holds two lines per card:
#
#   1 [WING           ]: USB-Audio - WING
#                        BEHRINGER WING at usb-0000:00:14.0-2, high speed
#
# Emit them as "index<TAB>id<TAB>driver<TAB>shortname<TAB>longname" so the
# matching below is a plain field comparison rather than a second parse.
vstos_list_cards() {
    [ -r "$VSTOS_ASOUND_CARDS" ] || return 0

    # Deliberately bash string handling rather than awk: Ubuntu Server ships mawk,
    # which has no three-argument match(), and a card resolver that works on the
    # developer's gawk box and not on the appliance is the worst kind of bug.
    local line idx="" id="" driver="" short="" long="" rest
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]*)\][[:space:]]*:[[:space:]]*(.*)$ ]]; then
            [ -n "$idx" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$id" "$driver" "$short" "$long"
            idx="${BASH_REMATCH[1]}"
            id="$(_vstos_trim "${BASH_REMATCH[2]}")"
            rest="${BASH_REMATCH[3]}"
            if [[ "$rest" =~ ^([^[:space:]]+)[[:space:]]+-[[:space:]]+(.*)$ ]]; then
                driver="${BASH_REMATCH[1]}"
                short="$(_vstos_trim "${BASH_REMATCH[2]}")"
            else
                driver="$(_vstos_trim "$rest")"
                short="$driver"
            fi
            long=""
        elif [ -n "$idx" ] && [ -z "$long" ]; then
            long="$(_vstos_trim "$line")"
        fi
    done < "$VSTOS_ASOUND_CARDS"
    [ -n "$idx" ] && printf '%s\t%s\t%s\t%s\t%s\n' "$idx" "$id" "$driver" "$short" "$long"
    return 0
}

# The USB product string as the device reports it, which is not always what ALSA
# shortens the card name to.
vstos_card_usb_product() {
    local idx="$1" f
    for f in "$VSTOS_ASOUND_DIR/card$idx/usbmixer" "$VSTOS_ASOUND_DIR/card$idx/stream0"; do
        [ -r "$f" ] || continue
        head -1 "$f" 2>/dev/null | sed 's/[[:space:]]*:.*$//'
        return 0
    done
    return 1
}

_vstos_ci_contains() {
    local haystack="${1,,}" needle="${2,,}"
    [ -n "$needle" ] || return 1
    [ "${haystack#*"$needle"}" != "$haystack" ]
}

# Print the ALSA device to hand jackd, e.g. "hw:WING". Non-zero and silent when
# nothing matches, so callers can decide whether that is fatal or a wait state.
vstos_resolve_device() {
    if [ -n "${AUDIO_DEVICE:-}" ]; then
        printf '%s\n' "$AUDIO_DEVICE"
        return 0
    fi

    local match="${AUDIO_DEVICE_MATCH:-}"
    local idx id driver short long product

    if [ -n "$match" ]; then
        while IFS=$'\t' read -r idx id driver short long; do
            [ -n "$idx" ] || continue
            if _vstos_ci_contains "$id" "$match" \
               || _vstos_ci_contains "$short" "$match" \
               || _vstos_ci_contains "$long" "$match"; then
                printf 'hw:%s\n' "$id"
                return 0
            fi
            product="$(vstos_card_usb_product "$idx" 2>/dev/null || true)"
            if [ -n "$product" ] && _vstos_ci_contains "$product" "$match"; then
                printf 'hw:%s\n' "$id"
                return 0
            fi
        done < <(vstos_list_cards)
    fi

    # Nothing matched. Only now, and only if asked, take whatever USB audio
    # device is present.
    if [ "${AUDIO_DEVICE_FALLBACK:-0}" = "1" ]; then
        while IFS=$'\t' read -r idx id driver short long; do
            [ "$driver" = "USB-Audio" ] || continue
            vstos_warn "no card matched '$match'; falling back to $id"
            printf 'hw:%s\n' "$id"
            return 0
        done < <(vstos_list_cards)
    fi

    return 1
}

# Is the engine up?
#
# Not `jack_wait -c` on its own: it exits 0 whether or not a server is there and
# reports the answer only on stdout ("running" / "not running"). Testing its exit
# status - the obvious thing to write - makes every caller believe the engine is
# always up, which turns "no sound" into a diagnostic that confidently points
# somewhere else.
vstos_jack_running() {
    command -v jack_wait >/dev/null 2>&1 || return 1
    local out
    out="$(JACK_NO_START_SERVER=1 jack_wait -c 2>/dev/null || true)"
    [ "$out" = "running" ]
}

# Block until the console appears. USB enumeration of a 48x48 interface is not
# instant, and a console powered on at the same moment as the host loses that
# race every time.
vstos_wait_for_device() {
    local timeout="${1:-30}" dev elapsed=0
    while :; do
        if dev="$(vstos_resolve_device)"; then
            printf '%s\n' "$dev"
            return 0
        fi
        [ "$elapsed" -ge "$timeout" ] && return 1
        sleep 1
        elapsed=$((elapsed + 1))
    done
}

# ---------------------------------------------------------------------------
# Plugin library
# ---------------------------------------------------------------------------

# Count plugin bundles of one kind, e.g. vstos_count_bundles lv2 /usr/lib/lv2 ...
#
# Filtering to directories that exist first is not tidiness. Callers run under
# `set -euo pipefail`, and `find` given a missing path exits non-zero, which takes
# the whole script down inside a command substitution - so /usr/local/lib/lv2 not
# existing, which is the normal case, would abort the caller.
vstos_count_bundles() {
    local ext="$1"; shift
    local dir dirs=()
    for dir in "$@"; do
        [ -d "$dir" ] && dirs+=("$dir")
    done
    if [ "${#dirs[@]}" -eq 0 ]; then
        printf '0\n'
        return 0
    fi
    find "${dirs[@]}" -maxdepth 1 -name "*.$ext" 2>/dev/null | wc -l
}

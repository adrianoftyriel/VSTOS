#!/usr/bin/env bash
# Helpers shared by the provisioning steps.
#
# shellcheck shell=bash

: "${VSTOS_SRC:?VSTOS_SRC must point at the repository root}"

VSTOS_CONF_PATH="${VSTOS_CONF_PATH:-/etc/vstos/vstos.conf}"
VSTOS_DRY_RUN="${VSTOS_DRY_RUN:-0}"

step_log()  { printf '  %s\n' "$*"; }
step_warn() { printf '  warning: %s\n' "$*" >&2; }
step_die()  { printf '  error: %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$VSTOS_DRY_RUN" = "1" ]; then
        printf '  [dry-run] %s\n' "$*"
        return 0
    fi
    "$@"
}

# Provisioning runs both on a live machine and inside the installer's chroot,
# where there is no running init to talk to. Everything that would need one is
# guarded on this.
vstos_have_systemd() {
    [ "${VSTOS_FORCE_NO_SYSTEMD:-0}" = "1" ] && return 1
    [ -d /run/systemd/system ]
}

# Read one value out of the installed config without sourcing the whole file into
# the provisioner's own namespace, where it would collide with step variables.
conf_get() {
    local key="$1" default="${2:-}" value
    if [ -r "$VSTOS_CONF_PATH" ]; then
        value="$(
            # shellcheck disable=SC1090
            . "$VSTOS_CONF_PATH" >/dev/null 2>&1
            printf '%s' "${!key:-}"
        )"
    fi
    printf '%s' "${value:-$default}"
}

# ---------------------------------------------------------------------------
# Installing files
# ---------------------------------------------------------------------------

install_file() {
    local src="$1" dest="$2" mode="${3:-0644}"
    [ -f "$src" ] || step_die "missing source file: $src"
    run install -D -m "$mode" "$src" "$dest"
    step_log "installed $dest"
}

# Substitute @PLACEHOLDER@ tokens from the configuration as the file is copied.
# Used for the handful of files that have to agree with vstos.conf and cannot read
# it themselves - systemd unit User= lines, udev match rules, the Carla settings.
#
# Fails loudly on a token left unsubstituted, because the alternative is a udev
# rule matching a device literally named @AUDIO_DEVICE_MATCH@, which matches
# nothing and says nothing.
install_template() {
    local src="$1" dest="$2" mode="$3"
    shift 3
    [ -f "$src" ] || step_die "missing template: $src"

    local tmp rc=0
    tmp="$(mktemp)"
    python3 "$VSTOS_SRC/provision/steps/render-template.py" "$src" "$tmp" "$@" || rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -f "$tmp"
        # Exit 3 is "a placeholder was left behind", which is the interesting case:
        # a udev rule matching a device literally named @AUDIO_DEVICE_MATCH@ matches
        # nothing and reports nothing. Fail here, where the message names the file.
        step_die "could not render $src (see the message above)"
    fi

    run install -D -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    step_log "installed $dest"
}

# ---------------------------------------------------------------------------
# Packages
# ---------------------------------------------------------------------------

# Package lists carry comments explaining why each entry is there, which is the
# only reason anyone will be able to prune them later. Strip them here.
read_package_list() {
    local list="$VSTOS_SRC/provision/packages/$1"
    [ -f "$list" ] || step_die "missing package list: $list"
    sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$'
}

apt_install() {
    [ "$#" -gt 0 ] || return 0
    # confdef/confold: if a package ever does ask about a modified configuration
    # file, answer "keep what is there" rather than letting dpkg block on a prompt
    # that has no terminal to appear on. Provisioning runs unattended, from an ISO
    # late-command as often as from a shell.
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        -o Dpkg::Use-Pty=0 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

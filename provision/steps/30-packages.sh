#!/usr/bin/env bash
# The package sets: base system, audio engine, session, plugin library.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# --no-install-recommends throughout (see apt_install). Recommends is how a
# minimal server install acquires a desktop: carla recommends nothing dangerous,
# but xserver-xorg-core's recommends pull in a display manager and half of GNOME's
# session plumbing on some releases. An appliance takes what it asks for.

step_log "base system"
# shellcheck disable=SC2046  # word splitting is the point: one package per line
apt_install $(read_package_list base.list)

step_log "audio engine and plugin host"
# shellcheck disable=SC2046  # word splitting is the point: one package per line
apt_install $(read_package_list audio.list)

# jackd2's package asks, interactively, whether to grant realtime privileges. On
# an unattended install that question has nowhere to go, so answer it in advance -
# and then do the job properly ourselves in 40-realtime.sh, because the package's
# own answer only edits /etc/security/limits.d/audio.conf.
step_log "pre-answering the jackd realtime prompt"
run debconf-set-selections <<'DEBEOF'
jackd2 jackd/tweak_rt_limits boolean true
jackd2 jackd2/tweak_rt_limits boolean true
DEBEOF

if [ "$(conf_get UI_MODE auto)" = "headless" ]; then
    # Nothing here is needed to load or run a plugin - only to show its editor.
    # Skipping it on a box that will never have a screen saves about 120 MB and,
    # more usefully, a set of packages that would otherwise want updating.
    step_log "UI_MODE=headless: skipping the X session packages"
else
    step_log "on-screen session"
    # shellcheck disable=SC2046  # word splitting is the point: one package per line
    apt_install $(read_package_list session.list)
fi

step_log "plugin library"
# lsp-plugins-vst3 comes from noble-backports, which Ubuntu enables by default but
# a hardened base image may not. Install the set as a whole first; if that fails,
# fall back to installing one at a time so a single unavailable package cannot
# cost the machine its entire plugin library.
# shellcheck disable=SC2046  # word splitting is the point: one package per line
if ! apt_install $(read_package_list plugins.list); then
    step_warn "installing the plugin set as a whole failed; retrying package by package"
    # shellcheck disable=SC2046  # word splitting is the point: one package per line
    for pkg in $(read_package_list plugins.list); do
        apt_install "$pkg" || step_warn "skipped $pkg (not available on this release)"
    done
fi

step_log "packages installed"

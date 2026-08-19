#!/usr/bin/env bash
# The session: commands, units, host settings and the rack that loads at boot.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

user="$(conf_get AUDIO_USER audio-op)"
# `|| true` because getent exits non-zero when the user does not exist, which is
# the normal case on a first run and under --dry-run, and under `set -e` that
# would end the step with no message at all.
home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6 || true)"
home="${home:-/var/lib/vstos/home}"

# --- commands ---------------------------------------------------------------
install_file "$VSTOS_SRC/system/bin/vstos-xsession" /usr/lib/vstos/vstos-xsession 0755
for cmd in vstos-jack vstos-session vstos-status; do
    install_file "$VSTOS_SRC/system/bin/$cmd" "/usr/bin/$cmd" 0755
done
install_file "$VSTOS_SRC/provision/vstos-apply" /usr/bin/vstos-apply 0755

# vstos-apply re-runs the later provisioning steps against the machine's own copy
# of this repository, so the copy has to survive the install. Without it, changing
# a buffer size in vstos.conf would mean fetching the project again on a machine
# that may have no network where it stands.
# When the ISO's late-command clones the repository straight to this path,
# VSTOS_SRC already *is* the destination and copying it into itself makes cp
# refuse ("are the same file"), which under set -e ends the install. Skip.
if [ "$(readlink -f "$VSTOS_SRC")" = "/usr/share/vstos/src" ]; then
    step_log "provisioning from /usr/share/vstos/src already; nothing to copy"
else
    run install -d -m 0755 /usr/share/vstos/src
    run cp -a "$VSTOS_SRC/provision" "$VSTOS_SRC/system" /usr/share/vstos/src/
    step_log "kept a copy of the provisioning tree at /usr/share/vstos/src"
fi

# The documentation goes with it, because the units point at it by path and an
# appliance with no browser is exactly where a man page in the wrong place stops
# being read.
run install -d -m 0755 /usr/share/doc/vstos
if [ -d "$VSTOS_SRC/docs" ]; then
    run cp -a "$VSTOS_SRC/docs/." /usr/share/doc/vstos/
    step_log "installed the documentation to /usr/share/doc/vstos"
fi

# --- session plumbing -------------------------------------------------------
if [ "$(conf_get UI_MODE auto)" != "headless" ]; then
    install_file "$VSTOS_SRC/system/xorg/Xwrapper.config" /etc/X11/Xwrapper.config 0644
    # Deliberately NOT /etc/xdg/openbox/rc.xml. That path is a dpkg conffile owned
    # by the openbox package: writing it makes every later openbox upgrade stop at
    # an interactive "keep your version or the maintainer's?" prompt, which under
    # apt's noninteractive frontend is not a prompt but a failed dpkg run and a
    # machine with packages half-configured. vstos-xsession passes --config-file.
    install_file "$VSTOS_SRC/system/openbox/rc.xml" /usr/share/vstos/openbox-rc.xml 0644
fi

# --- host settings ----------------------------------------------------------
# Carla keeps its settings in a Qt ini under the session user's home, so this has
# to be written there and owned by them - Carla rewrites the file whenever
# anything is changed in its own settings dialog.
osc_enabled=false
[ "$(conf_get OSC_ENABLED 1)" = "1" ] && osc_enabled=true
install_template "$VSTOS_SRC/system/carla/Carla2.conf.tmpl" \
                 "$home/.config/falkTX/Carla2.conf" 0644 \
                 "OSC_ENABLED=$osc_enabled" \
                 "OSC_PORT=$(conf_get OSC_PORT 22752)"

# --- the boot rack ----------------------------------------------------------
project="$(conf_get CARLA_PROJECT /var/lib/vstos/projects/default.carxp)"
if [ -f "$project" ]; then
    # Someone has saved their own rack over the shipped one. It is the most
    # valuable file on the machine; leave it alone.
    step_log "keeping the existing rack at $project"
else
    install_template "$VSTOS_SRC/system/carla/default.carxp.tmpl" "$project" 0644 \
                     "INSERT_CHANNEL=$(conf_get INSERT_CHANNEL 1)"
fi

run chown -R "$user":audio "$home" /var/lib/vstos 2>/dev/null || \
    step_warn "could not chown the session directories"

# --- units ------------------------------------------------------------------
for unit in vstos-jack vstos-a2jmidi vstos-session; do
    install_template "$VSTOS_SRC/system/systemd/$unit.service" \
                     "/etc/systemd/system/$unit.service" 0644 \
                     "AUDIO_USER=$user"
done

# The engine restarting forever is the intended behaviour, not a fault to be rate
# limited: the console may be plugged in an hour after the host boots. systemd's
# default of five starts in ten seconds would put the unit in `failed` long before
# then and leave it there.
run install -d -m 0755 /etc/systemd/system/vstos-jack.service.d
run tee /etc/systemd/system/vstos-jack.service.d/10-no-start-limit.conf >/dev/null <<'DROPEOF'
[Unit]
StartLimitIntervalSec=0
DROPEOF

if vstos_have_systemd; then
    run systemctl daemon-reload
fi

run systemctl enable vstos-jack.service vstos-session.service >/dev/null 2>&1 || \
    step_warn "could not enable the session units"

if [ "$(conf_get MIDI_BRIDGE 1)" = "1" ]; then
    run systemctl enable vstos-a2jmidi.service >/dev/null 2>&1 || \
        step_warn "could not enable the MIDI bridge"
else
    run systemctl disable vstos-a2jmidi.service >/dev/null 2>&1 || true
    step_log "MIDI_BRIDGE=0: the console's USB MIDI will not be bridged"
fi

step_log "session installed"

#!/usr/bin/env bash
# Realtime scheduling, memory locking, CPU governor and device rules.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# The runtime library first: steps 60 and 70 source it, and it is the first thing
# vstos-apply needs when it re-runs this range after a configuration change.
install_file "$VSTOS_SRC/system/bin/vstos-lib.sh" /usr/lib/vstos/vstos-lib.sh 0644

install_file "$VSTOS_SRC/system/limits/95-vstos-audio.conf" \
             /etc/security/limits.d/95-vstos-audio.conf 0644
install_file "$VSTOS_SRC/system/sysctl/95-vstos-audio.conf" \
             /etc/sysctl.d/95-vstos-audio.conf 0644

# The udev rule has to name the same device the resolver looks for, and it cannot
# read the config file itself, so it is rendered from it.
install_template "$VSTOS_SRC/system/udev/89-vstos-console.rules" \
                 /etc/udev/rules.d/89-vstos-console.rules 0644 \
                 "AUDIO_DEVICE_MATCH=$(conf_get AUDIO_DEVICE_MATCH WING)"

# CPU frequency governor. Set through a unit rather than by writing to sysfs here,
# because sysfs does not survive a reboot and, on a machine provisioned inside the
# installer's chroot, is not writable at all.
governor="$(conf_get CPU_GOVERNOR performance)"
run tee /etc/systemd/system/vstos-cpu-governor.service >/dev/null <<UNITEOF
[Unit]
Description=VSTOS CPU frequency governor ($governor)
Documentation=file:/usr/share/doc/vstos/DESIGN.md
After=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
# Not every machine exposes a governor - a VM usually does not, and a bare-metal
# box booted with intel_pstate in passive mode exposes a different set. Missing is
# not a failure; it just means there is nothing to pin.
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -w "\$c" ] && echo $governor > "\$c"; done; exit 0'

[Install]
WantedBy=multi-user.target
UNITEOF
step_log "installed /etc/systemd/system/vstos-cpu-governor.service ($governor)"

if vstos_have_systemd; then
    run systemctl daemon-reload
    run sysctl --system >/dev/null 2>&1 || step_warn "sysctl --system reported an error"
    run udevadm control --reload-rules 2>/dev/null || true
fi
run systemctl enable vstos-cpu-governor.service >/dev/null 2>&1 || \
    step_warn "could not enable vstos-cpu-governor.service"

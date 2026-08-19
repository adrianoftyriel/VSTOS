#!/usr/bin/env bash
# Take out what an appliance does not need, and bound what is left.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# Services that are reasonable on a server and wrong on an audio appliance.
#
# unattended-upgrades is the important one. It is exactly right on a server and
# exactly wrong here: it wakes up on its own schedule, and the CPU and disk it
# uses to do it lands in the middle of whatever is being processed. Updating the
# machine is a decision to take between services, not during one.
for svc in unattended-upgrades apt-daily.timer apt-daily-upgrade.timer \
           motd-news.timer man-db.timer fstrim.timer; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1; then
        run systemctl disable --now "$svc" >/dev/null 2>&1 || \
            run systemctl disable "$svc" >/dev/null 2>&1 || true
    fi
done
step_log "disabled the background maintenance timers"

# ModemManager and friends probe serial devices on hotplug, which on a machine
# whose whole purpose is a USB device is unnecessary work at the worst moment.
for svc in ModemManager bluetooth cups cups-browsed avahi-daemon.socket; do
    systemctl list-unit-files "$svc" >/dev/null 2>&1 && \
        run systemctl disable "$svc" >/dev/null 2>&1 || true
done

# Avahi itself stays: finding the box as vstos.local is worth more than the
# handful of packets it costs, on a machine that will be plugged into networks
# nobody controls.
systemctl list-unit-files avahi-daemon.service >/dev/null 2>&1 && \
    run systemctl enable avahi-daemon.service >/dev/null 2>&1 || true

# Bound the journal. An appliance that runs for a year should not fill its disk
# with its own logs, and a persistent journal is what makes "it dropped out during
# the second reading" answerable a week later.
run install -d -m 0755 /etc/systemd/journald.conf.d
run tee /etc/systemd/journald.conf.d/95-vstos.conf >/dev/null <<'JEOF'
[Journal]
Storage=persistent
SystemMaxUse=512M
SystemMaxFileSize=64M
MaxRetentionSec=1month
JEOF
step_log "journal bounded to 512M, kept for a month"

# The login banner is where an operator with a keyboard and no documentation
# finds out what this machine is.
run tee /etc/issue >/dev/null <<'IEOF'

VSTOS - purpose-built audio host

  vstos-status        is anything wrong, and what
  systemctl status vstos-jack vstos-session
  /etc/vstos/vstos.conf   sample rate, buffer size, which channel

IEOF
run cp /etc/issue /etc/issue.net 2>/dev/null || true

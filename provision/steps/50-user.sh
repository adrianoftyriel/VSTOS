#!/usr/bin/env bash
# The unprivileged account that owns the session, and the state it writes to.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

user="$(conf_get AUDIO_USER audio-op)"

# The audio group is what /etc/security/limits.d/95-vstos-audio.conf grants
# realtime privileges to. jackd2 creates it; create it here too so the ordering
# between steps cannot matter.
getent group audio >/dev/null || run groupadd --system audio

if getent passwd "$user" >/dev/null; then
    step_log "user $user already exists"
else
    # No password and no shell login. The account exists to own a process, and
    # administration happens over SSH as the admin user created by the installer.
    run useradd --system --create-home --home-dir "/var/lib/vstos/home" \
        --shell /usr/sbin/nologin --comment "VSTOS plugin host session" "$user"
    step_log "created $user"
fi

# video and input: the session needs the DRM device and the keyboard/mouse to run
# an X server. render: some GPU drivers put buffer allocation on a separate node.
for grp in audio video input render plugdev; do
    getent group "$grp" >/dev/null && run usermod -aG "$grp" "$user"
done
step_log "$user is in: $(id -nG "$user" 2>/dev/null || echo '(pending)')"

for dir in /var/lib/vstos /var/lib/vstos/home /var/lib/vstos/projects /var/lib/vstos/presets; do
    run install -d -m 0755 -o "$user" -g audio "$dir"
done
step_log "state directories under /var/lib/vstos"

#!/usr/bin/env bash
# Put the configuration in place. Everything after this reads it.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

run install -d -m 0755 /etc/vstos

# Never overwrite a config that is already there. Re-provisioning a machine that
# has been tuned for its own USB timing must not silently reset PERIOD to the
# default and hand back a rig that xruns.
if [ -f "$VSTOS_CONF_PATH" ]; then
    step_log "keeping the existing $VSTOS_CONF_PATH"
    step_log "the shipped defaults are in /usr/share/vstos/vstos.conf.default if you want to compare"
else
    install_file "$VSTOS_SRC/provision/vstos.conf.default" "$VSTOS_CONF_PATH" 0644
fi

# A pristine copy, so a machine can always be diffed against what it shipped with.
install_file "$VSTOS_SRC/provision/vstos.conf.default" /usr/share/vstos/vstos.conf.default 0644

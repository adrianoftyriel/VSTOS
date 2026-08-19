#!/usr/bin/env bash
# FBKSuppressor, and a look at what the plugin library actually amounts to.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

install_file "$VSTOS_SRC/system/bin/vstos-install-fbksuppressor" \
             /usr/bin/vstos-install-fbksuppressor 0755

# FBK_RELEASE pins a tag; unset means the newest release, pre-releases included.
# It is an environment variable rather than a vstos.conf key because it is a
# property of a particular build of the image, not of the machine: two boxes
# provisioned a month apart should be allowed to differ, and vstos-status reports
# which one each is running.
release="${FBK_RELEASE:-}"

if [ "${VSTOS_OFFLINE:-0}" = "1" ]; then
    step_warn "VSTOS_OFFLINE=1: skipping the FBKSuppressor download"
    step_warn "run vstos-install-fbksuppressor on the machine once it has network"
elif run /usr/bin/vstos-install-fbksuppressor "$release"; then
    step_log "FBKSuppressor $(cat /usr/lib/vstos/fbksuppressor.version 2>/dev/null || echo installed)"
else
    # Not fatal. Everything else about the machine is still correct, the plugin
    # library still works, and the one missing piece is installable later with a
    # single command that vstos-status tells you to run. Failing the whole
    # provisioning run over a network problem would be worse.
    step_warn "could not install FBKSuppressor (network, or a private repository needing GITHUB_TOKEN)"
    step_warn "run vstos-install-fbksuppressor on the machine to finish"
fi

if [ "$VSTOS_DRY_RUN" != "1" ] && [ -r /usr/lib/vstos/vstos-lib.sh ]; then
    # shellcheck source=../../system/bin/vstos-lib.sh
    . /usr/lib/vstos/vstos-lib.sh
    step_log "plugin library: $(vstos_count_bundles lv2 /usr/lib/lv2 /usr/local/lib/lv2) LV2 bundles, $(vstos_count_bundles vst3 /usr/lib/vst3 /usr/local/lib/vst3) VST3 bundles"
fi

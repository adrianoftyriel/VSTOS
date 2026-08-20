#!/usr/bin/env bash
# Refuse to start if this is not something VSTOS can turn into an appliance.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

[ "$(id -u)" -eq 0 ] || step_die "provisioning must run as root"

# shellcheck disable=SC1091
. /etc/os-release 2>/dev/null || step_die "no /etc/os-release; this is not a Debian-family system"

step_log "target: ${PRETTY_NAME:-unknown}"

case "${ID:-}" in
    ubuntu) ;;
    debian) step_warn "Debian is untested. The package names mostly match; the kernel step does not." ;;
    *)      step_die "VSTOS provisions Ubuntu (found ID=${ID:-none})" ;;
esac

# Both LTS releases are supported and tested. The package lists carry per-release
# entries where the names differ, and VSTOS_KNOWN_RELEASES in lib.sh is the list
# those entries are validated against - so this check and that one cannot drift.
codename="$(vstos_codename)"
supported=0
for r in $VSTOS_KNOWN_RELEASES; do
    [ "$r" = "$codename" ] && supported=1
done
if [ "$supported" = 1 ]; then
    step_log "release: $codename (${VERSION_ID:-?}), supported"
else
    step_warn "$codename (${VERSION_ID:-unknown}) is not a release VSTOS has been built against"
    step_warn "supported: $VSTOS_KNOWN_RELEASES - package names may differ, and the kernel step will find nothing to install"
fi

# An appliance with no console attached is normal; an appliance with no network at
# provisioning time is not, because every package comes from the archive.
if ! run apt-get -qq update >/dev/null 2>&1; then
    step_die "cannot reach the package archive; provisioning needs network"
fi

step_log "architecture: $(dpkg --print-architecture)"
step_log "preflight passed"

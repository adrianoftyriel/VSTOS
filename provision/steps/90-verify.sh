#!/usr/bin/env bash
# Check that provisioning produced what it claimed to. Reports; does not fix.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# Under --dry-run nothing was installed, so every check would fail and the run
# would end on a page of red that means nothing.
if [ "$VSTOS_DRY_RUN" = "1" ]; then
    step_log "dry run: skipping verification, since nothing was installed"
    exit 0
fi

problems=0
check() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then
        step_log "ok    $what"
    else
        step_warn "FAIL  $what"
        problems=$((problems + 1))
    fi
}

check "configuration installed"      test -f /etc/vstos/vstos.conf
check "runtime library installed"    test -f /usr/lib/vstos/vstos-lib.sh
check "vstos-jack installed"         test -x /usr/bin/vstos-jack
check "vstos-session installed"      test -x /usr/bin/vstos-session
check "vstos-status installed"       test -x /usr/bin/vstos-status
check "jackd present"                command -v jackd
check "carla present"                command -v carla
check "realtime limits installed"    test -f /etc/security/limits.d/95-vstos-audio.conf
check "engine unit installed"        test -f /etc/systemd/system/vstos-jack.service
check "session unit installed"       test -f /etc/systemd/system/vstos-session.service
check "boot rack present"            test -f "$(conf_get CARLA_PROJECT /var/lib/vstos/projects/default.carxp)"
check "session user exists"          getent passwd "$(conf_get AUDIO_USER audio-op)"

# The library is the point of the exercise, so count it rather than trusting that
# apt said yes.
if [ -r /usr/lib/vstos/vstos-lib.sh ]; then
    # shellcheck source=../../system/bin/vstos-lib.sh
    . /usr/lib/vstos/vstos-lib.sh
    lv2="$(vstos_count_bundles lv2 /usr/lib/lv2 /usr/local/lib/lv2)"
else
    lv2=0
fi
if [ "$lv2" -ge 10 ]; then
    step_log "ok    plugin library ($lv2 LV2 bundles)"
else
    step_warn "FAIL  plugin library looks thin ($lv2 LV2 bundles)"
    problems=$((problems + 1))
fi

if [ -e /usr/lib/vst3/FBKSuppressor.vst3 ]; then
    step_log "ok    FBKSuppressor $(cat /usr/lib/vstos/fbksuppressor.version 2>/dev/null || echo installed)"
else
    step_warn "note  FBKSuppressor is not installed yet - run vstos-install-fbksuppressor"
fi

# The config has to parse, or every unit fails at once with the same message.
if VSTOS_CONF=/etc/vstos/vstos.conf bash -c '. /usr/lib/vstos/vstos-lib.sh; vstos_load_conf' >/dev/null 2>&1; then
    step_log "ok    configuration is valid"
else
    step_warn "FAIL  /etc/vstos/vstos.conf is not valid:"
    VSTOS_CONF=/etc/vstos/vstos.conf bash -c '. /usr/lib/vstos/vstos-lib.sh; vstos_load_conf' 2>&1 | sed 's/^/        /' >&2
    problems=$((problems + 1))
fi

if [ "$problems" -gt 0 ]; then
    step_warn "$problems check(s) failed"
    exit 1
fi
step_log "all checks passed"

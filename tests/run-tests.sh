#!/usr/bin/env bash
# The VSTOS test suite.
#
#   ./tests/run-tests.sh            everything available on this machine
#   ./tests/run-tests.sh --list     the test names
#   ./tests/run-tests.sh resolver   just the tests whose name contains "resolver"
#
# Tests that need something this machine may not have - shellcheck, carla, a JACK
# server - skip rather than fail, and say so. A suite that cannot run anywhere
# except one developer's laptop gets ignored.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PASS=0; FAIL=0; SKIP=0
FILTER="${1:-}"
[ "$FILTER" = "--list" ] && { grep -oP '^t_\K[a-z0-9_]+' "$0" | sed 's/^/  /'; exit 0; }

ok()   { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mskip\033[0m %s\n' "$*"; }

assert_eq() {
    local want="$1" got="$2" what="$3"
    if [ "$want" = "$got" ]; then ok "$what"; else bad "$what (want '$want', got '$got')"; fi
}
assert_ok()   { if "${@:2}" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
assert_fail() { if "${@:2}" >/dev/null 2>&1; then bad "$1 (should have failed)"; else ok "$1"; fi; }

# ---------------------------------------------------------------------------

t_shellcheck() {
    command -v shellcheck >/dev/null || { skip "shellcheck is not installed"; return; }
    local files
    mapfile -t files < <(
        printf '%s\n' provision/vstos-provision provision/vstos-apply \
                      provision/steps/*.sh build/build-iso.sh tests/run-tests.sh
        find system/bin -type f
    )
    # SC1091 only: the runtime library is sourced from an absolute install path
    # that does not exist in the source tree.
    if shellcheck -S warning -e SC1091 "${files[@]}"; then
        ok "shellcheck is clean across ${#files[@]} scripts"
    else
        bad "shellcheck reported problems"
    fi
}

t_bash_syntax() {
    local f bad_any=0
    while IFS= read -r f; do
        bash -n "$f" 2>/dev/null || { bad "bash -n $f"; bad_any=1; }
        # system/systemd holds unit files, which are ini, not shell - and
        # vstos-jack.service would otherwise be handed to bash -n.
    done < <(find provision system/bin tests build -type f \( -name '*.sh' -o -name 'vstos-*' \) 2>/dev/null)
    [ "$bad_any" -eq 0 ] && ok "every shell script parses"
}

t_python_syntax() {
    local f
    for f in provision/steps/render-template.py build/patch-grub-cfg.py; do
        if python3 -c "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())" "$f"; then
            ok "python parses: $f"
        else
            bad "python does not parse: $f"
        fi
    done
}

t_xml_wellformed() {
    local f
    for f in system/openbox/rc.xml system/carla/default.carxp.tmpl; do
        if python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$f" 2>/dev/null; then
            ok "well-formed XML: $f"
        else
            bad "malformed XML: $f"
        fi
    done
}

t_resolver() {
    local lib="system/bin/vstos-lib.sh" out
    run_resolver() {
        env VSTOS_ASOUND_CARDS="tests/fixtures/$1" VSTOS_ASOUND_DIR=/nonexistent \
            AUDIO_DEVICE="${2:-}" AUDIO_DEVICE_MATCH="${3:-WING}" AUDIO_DEVICE_FALLBACK="${4:-0}" \
            bash -c ". $lib; vstos_resolve_device 2>/dev/null || echo NONE"
    }
    assert_eq "hw:WING" "$(run_resolver cards-wing)"                       "resolver finds the WING"
    assert_eq "hw:Rack" "$(run_resolver cards-wing-rack)"                  "resolver finds a WING Rack"
    assert_eq "hw:WING" "$(run_resolver cards-wing '' wing)"               "resolver matching is case-insensitive"
    assert_eq "NONE"    "$(run_resolver cards-none)"                       "resolver reports nothing when no card is present"
    assert_eq "NONE"    "$(run_resolver cards-other-usb)"                  "resolver refuses an unrelated USB interface"
    assert_eq "hw:USB"  "$(run_resolver cards-other-usb '' WING 1)"        "resolver falls back when told to"
    assert_eq "hw:3"    "$(run_resolver cards-wing hw:3)"                  "AUDIO_DEVICE overrides matching"

    out="$(env VSTOS_ASOUND_CARDS=tests/fixtures/cards-wing bash -c ". $lib; vstos_list_cards" | wc -l)"
    assert_eq "2" "$out" "resolver parses both cards from /proc/asound/cards"
}

t_config_validation() {
    local lib="system/bin/vstos-lib.sh"
    check_conf() {
        local body="$1" tmp
        tmp="$(mktemp)"
        printf '%s\n' "$body" > "$tmp"
        env VSTOS_CONF="$tmp" bash -c ". $lib; vstos_load_conf" >/dev/null 2>&1
        local rc=$?
        rm -f "$tmp"
        return $rc
    }
    assert_ok   "the shipped defaults are valid"        check_conf "$(cat provision/vstos.conf.default)"
    assert_fail "a bad sample rate is rejected"         check_conf 'SAMPLE_RATE=96000'
    assert_fail "a non-power-of-two period is rejected" check_conf 'PERIOD=100'
    assert_fail "a bad nperiods is rejected"            check_conf 'NPERIODS=9'
    assert_fail "an out-of-range RT priority is rejected" check_conf 'JACK_RT_PRIORITY=99'
    assert_fail "an unknown UI_MODE is rejected"        check_conf 'UI_MODE=wayland'
    assert_fail "an out-of-range insert channel is rejected" check_conf 'INSERT_CHANNEL=64'
    assert_ok   "channel 48 is accepted"                check_conf 'INSERT_CHANNEL=48'
}

t_template_renderer() {
    local tmp out
    tmp="$(mktemp)"; out="$(mktemp)"
    printf 'a=@ONE@ b=@TWO@\n' > "$tmp"

    python3 provision/steps/render-template.py "$tmp" "$out" ONE=1 TWO=2 2>/dev/null
    assert_eq "a=1 b=2" "$(cat "$out")" "renderer substitutes every placeholder"

    assert_fail "renderer refuses a template with an unsupplied placeholder" \
        python3 provision/steps/render-template.py "$tmp" "$out" ONE=1

    # A value that contains another placeholder must be left alone, not rewritten.
    python3 provision/steps/render-template.py "$tmp" "$out" 'ONE=@TWO@' TWO=2 2>/dev/null
    assert_eq "a=@TWO@ b=2" "$(cat "$out")" "renderer does not re-substitute inside a value"
    rm -f "$tmp" "$out"
}

t_grub_patcher() {
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<'GEOF'
menuentry "a" {
	linux	/casper/vmlinuz  ---
}
menuentry "b" {
	linux	/casper/hwe-vmlinuz  ---
}
menuentry "c" {
	linux	/casper/vmlinuz quiet
}
GEOF
    python3 build/patch-grub-cfg.py "$tmp" 2>/dev/null
    assert_eq "3" "$(grep -c 'autoinstall' "$tmp")" "grub patcher patches every kernel entry, HWE included"

    python3 build/patch-grub-cfg.py "$tmp" 2>/dev/null
    assert_eq "3" "$(grep -c 'autoinstall' "$tmp")" "grub patcher is idempotent"

    printf 'set timeout=5\n' > "$tmp"
    assert_fail "grub patcher fails when there is nothing to patch" \
        python3 build/patch-grub-cfg.py "$tmp"
    rm -f "$tmp"
}

t_autoinstall_yaml() {
    local out
    out="$(mktemp)"
    if ! python3 provision/steps/render-template.py build/autoinstall/user-data.tmpl "$out" \
        HOSTNAME=vstos ADMIN_USER=vstos 'ADMIN_PASSWORD_HASH=$6$x$y' \
        LOCALE=en_GB.UTF-8 KEYBOARD=gb \
        VSTOS_REPO=https://example.invalid/VSTOS.git VSTOS_BRANCH=main FBK_RELEASE= 2>/dev/null
    then
        bad "the autoinstall template does not render"
        rm -f "$out"; return
    fi
    ok "the autoinstall template renders"

    if ! python3 -c "import yaml" 2>/dev/null; then
        skip "pyyaml is not installed; not parsing the autoinstall output"
        rm -f "$out"; return
    fi
    if python3 -c "
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
ai = d['autoinstall']
assert ai['version'] == 1, ai['version']
assert ai['identity']['hostname'] == 'vstos'
assert any('vstos-provision' in c for c in ai['late-commands']), 'provisioner is never invoked'
" "$out" 2>/dev/null; then
        ok "the rendered autoinstall is valid and runs the provisioner"
    else
        bad "the rendered autoinstall is not valid autoinstall YAML"
    fi
    rm -f "$out"
}

t_systemd_units() {
    command -v systemd-analyze >/dev/null || { skip "systemd-analyze is not installed"; return; }
    local dir unit out
    dir="$(mktemp -d)"
    # The units ship with a placeholder for the session user, so render them the
    # way provisioning does before asking systemd whether they are valid.
    for unit in system/systemd/*.service; do
        python3 provision/steps/render-template.py "$unit" "$dir/$(basename "$unit")" \
            AUDIO_USER=audio-op 2>/dev/null
    done
    # Stub the binaries: systemd-analyze checks that ExecStart exists, and it does
    # not on a build machine.
    mkdir -p "$dir/bin"
    for b in vstos-jack vstos-session a2jmidid; do printf '#!/bin/sh\n' > "$dir/bin/$b"; chmod +x "$dir/bin/$b"; done

    # Filter what is about the environment rather than the units: stub binaries,
    # the placeholder-looking user name, and containers without IPv6 or with a
    # different unit tree.
    out="$(cd "$dir" && systemd-analyze verify ./*.service 2>&1 |
           grep -viE "not executable|does not match strict user|Unit .* not found|IPv6|Failed to (open|read)" || true)"
    if [ -z "$out" ]; then
        ok "systemd accepts all three units"
    else
        bad "systemd-analyze objected: $out"
    fi
    rm -rf "$dir"
}

t_unit_placeholders() {
    # Every @PLACEHOLDER@ in a shipped template must be one provisioning supplies.
    local known=" AUDIO_USER AUDIO_DEVICE_MATCH INSERT_CHANNEL OSC_ENABLED OSC_PORT HOSTNAME ADMIN_USER ADMIN_PASSWORD_HASH LOCALE KEYBOARD VSTOS_REPO VSTOS_BRANCH FBK_RELEASE "
    local f tok missing=""
    while IFS= read -r f; do
        while read -r tok; do
            tok="${tok//@/}"
            [[ "$known" == *" $tok "* ]] || missing="$missing $f:$tok"
        done < <(grep -oh '@[A-Z_][A-Z0-9_]*@' "$f" 2>/dev/null | sort -u)
    done < <(find system build -type f \( -name '*.tmpl' -o -name '*.service' -o -name '*.rules' \))
    if [ -z "$missing" ]; then
        ok "every template placeholder is one provisioning knows how to fill"
    else
        bad "templates use placeholders nothing supplies:$missing"
    fi
}

t_package_lists() {
    command -v apt-cache >/dev/null || { skip "apt-cache is not available"; return; }
    local list pkg missing="" checked=0
    for list in provision/packages/*.list; do
        while read -r pkg; do
            [ -n "$pkg" ] || continue
            checked=$((checked+1))
            # Not `apt-cache policy ... | grep -q`. Under `set -o pipefail`,
            # grep -q closes the pipe as soon as it matches, apt-cache dies of
            # SIGPIPE, and pipefail turns a successful match into a failed
            # pipeline - so every package would be reported missing.
            local policy
            policy="$(apt-cache policy "$pkg" 2>/dev/null || true)"
            case "$policy" in
                *"Candidate: (none)"*|"") missing="$missing $(basename "$list"):$pkg" ;;
                *"Candidate: "*)          : ;;
                *)                        missing="$missing $(basename "$list"):$pkg" ;;
            esac
        done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$')
    done
    if [ -z "$missing" ]; then
        ok "all $checked packages resolve in the configured archives"
    else
        # Not a failure: the lists are correct for Ubuntu 24.04, and the suite may
        # be running somewhere else entirely.
        skip "packages not available here (fine unless this is 24.04):$missing"
    fi
}

t_carla_loads_boot_rack() {
    command -v carla >/dev/null || { skip "carla is not installed"; return; }
    [ -e /usr/lib/vst3/FBKSuppressor.vst3 ] || { skip "FBKSuppressor is not installed"; return; }
    command -v jackd >/dev/null || { skip "jackd is not installed"; return; }

    local py
    py="$(command -v python3.12 || command -v python3)"
    if ! "$py" -c "import sys; sys.path.insert(0,'/usr/share/carla'); import carla_backend" 2>/dev/null; then
        skip "carla's python backend is not importable by $py"
        return
    fi

    local work started=0
    work="$(mktemp -d)"
    if ! JACK_NO_START_SERVER=1 jack_wait -c >/dev/null 2>&1; then
        JACK_NO_AUDIO_RESERVATION=1 jackd -d dummy -r 48000 -p 128 >"$work/jackd.log" 2>&1 &
        started=$!
        local i=0
        until JACK_NO_START_SERVER=1 jack_wait -c >/dev/null 2>&1 || [ "$i" -ge 10 ]; do
            sleep 1; i=$((i+1))
        done
    fi

    python3 provision/steps/render-template.py \
        system/carla/default.carxp.tmpl "$work/boot.carxp" INSERT_CHANNEL=1 2>/dev/null

    if "$py" tests/load-project.py "$work/boot.carxp" >"$work/out" 2>&1; then
        ok "carla loads the boot rack and instantiates FBKSuppressor"
    else
        bad "carla could not load the boot rack: $(tail -3 "$work/out" | tr '\n' ' ')"
    fi
    [ "$started" != 0 ] && kill "$started" 2>/dev/null
    rm -rf "$work"
}

# ---------------------------------------------------------------------------

printf '\033[1mVSTOS tests\033[0m\n'
for t in $(grep -oP '^t_\K[a-z0-9_]+' "$0"); do
    [ -n "$FILTER" ] && [[ "$t" != *"$FILTER"* ]] && continue
    printf '\n%s\n' "$t"
    "t_$t"
done

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# The low-latency kernel, and the boot parameters that make USB audio behave.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# Installing a kernel is meaningless inside a container, which boots the host's,
# and it is the slowest step by a wide margin. CI and container smoke tests set
# this; a real machine must not, or it will come up on the generic kernel with no
# tuning at all.
if [ "${VSTOS_SKIP_KERNEL:-0}" = "1" ]; then
    step_log "VSTOS_SKIP_KERNEL=1: not installing a kernel or touching the boot menu"
    exit 0
fi

# Which package that is differs by release, and packages/kernel.list holds both
# with the reasoning. Both resolve to the generic 7.0 kernel plus Canonical's
# lowlatency-kernel tuning package.
step_log "installing the low-latency kernel for $(vstos_codename)"
# shellcheck disable=SC2046  # word splitting is the point: one package per line
apt_install $(read_package_list kernel.list)

# Boot parameters.
#
#   threadirqs             - run interrupt handlers in schedulable threads, so the
#                            USB controller's handler can be prioritised against
#                            audio processing instead of preempting it blindly.
#   usbcore.autosuspend=-1 - never power-manage a USB device. A console that
#                            autosuspends between soundchecks comes back as a new
#                            card index, and the rig is pointing at nothing.
#
# These are additions to, not a replacement for, what lowlatency-kernel sets.
# That package drops /etc/default/grub.d/99-lowlatency.cfg carrying
# `preempt=full rcu_nocbs=all`, and grub sources that directory in glob order, so
# 99-lowlatency.cfg is read before 99-vstos.cfg and both append to the same
# variable. The machine boots with all four. Nothing here needs to repeat
# preempt=full, and repeating it would only make the eventual command line
# confusing to read.
#
# Not set, deliberately: mitigations=off. It buys real CPU headroom and is widely
# recommended for audio machines, and it turns off the CPU vulnerability
# mitigations to get it. On a box that sits on a venue's network that is a
# judgement for the operator, not a default; docs/DESIGN.md says how to enable it.
# Read from system/kernel-cmdline so the installed path and the live-USB image
# cannot drift apart. See that file for what each parameter is for.
VSTOS_CMDLINE="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$VSTOS_SRC/system/kernel-cmdline" | tr '\n' ' ')"
VSTOS_CMDLINE="$(_step_trim "$VSTOS_CMDLINE")"
[ -n "$VSTOS_CMDLINE" ] || step_die "system/kernel-cmdline is empty"

GRUB_D=/etc/default/grub.d
run install -d -m 0755 "$GRUB_D"
run tee "$GRUB_D/99-vstos.cfg" >/dev/null <<GRUBEOF
# Managed by VSTOS. Edit /etc/vstos/vstos.conf and re-run vstos-apply instead.
#
# Appends to whatever /etc/default/grub.d/99-lowlatency.cfg has already set, so
# the result is: preempt=full rcu_nocbs=all $VSTOS_CMDLINE
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $VSTOS_CMDLINE"

# No menu wait on an appliance that has one thing to boot. Held, not zero, so a
# machine that needs a recovery kernel can still be caught.
GRUB_TIMEOUT=2
GRUB_TIMEOUT_STYLE=menu
GRUBEOF
step_log "installed $GRUB_D/99-vstos.cfg ($VSTOS_CMDLINE)"

if command -v update-grub >/dev/null 2>&1; then
    run update-grub >/dev/null 2>&1 || step_warn "update-grub failed; run it by hand before rebooting"
fi

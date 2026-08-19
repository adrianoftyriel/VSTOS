#!/usr/bin/env bash
# The low-latency kernel, and the boot parameters that make USB audio behave.
set -euo pipefail
# shellcheck source=lib.sh
. "$VSTOS_SRC/provision/steps/lib.sh"

# Installing a kernel is meaningless inside a container, which boots the host's,
# and it is the slowest step by a wide margin. CI and container smoke tests set
# this; a real machine must not, or it will come up on the generic kernel.
if [ "${VSTOS_SKIP_KERNEL:-0}" = "1" ]; then
    step_log "VSTOS_SKIP_KERNEL=1: not installing a kernel or touching the boot menu"
    exit 0
fi

# shellcheck disable=SC1091
. /etc/os-release

# Ubuntu changed how "the lowlatency kernel" is delivered between 24.04 and 26.04,
# and both answers are correct for their own release:
#
#   24.04 - a separate kernel flavour, built with a 1000 Hz tick and full
#           preemption. linux-lowlatency-hwe-24.04 is its hardware-enablement
#           track, which currently carries kernel 7.0.
#   26.04 - the flavour is retired. The generic kernel gained boot-time
#           responsiveness tuning, and lowlatency-kernel is a small user-space
#           package whose job is to set the GRUB command line for it.
#
# Choosing by release rather than pinning one name is what lets the base move
# forward without this becoming a machine that quietly boots a desktop kernel.
case "${VERSION_ID:-}" in
    26.04|26.*|27.*)
        step_log "installing linux-generic with the lowlatency-kernel tuning package"
        apt_install linux-generic lowlatency-kernel
        ;;
    *)
        step_log "installing the lowlatency kernel flavour"
        # shellcheck disable=SC2046  # word splitting is the point: one package per line
        apt_install $(read_package_list kernel.list)
        ;;
esac

# Boot parameters.
#
#   threadirqs             - run interrupt handlers in schedulable threads, so the
#                            USB controller's handler can be prioritised against
#                            audio processing instead of preempting it blindly.
#   usbcore.autosuspend=-1 - never power-manage a USB device. A console that
#                            autosuspends between soundchecks comes back as a new
#                            card index, and the rig is pointing at nothing.
#
# Not set, deliberately: mitigations=off. It buys real CPU headroom and is widely
# recommended for audio machines, and it turns off the CPU vulnerability
# mitigations to get it. On a box that sits on a venue's network that is a
# judgement for the operator, not a default; docs/DESIGN.md says how to enable it.
VSTOS_CMDLINE="threadirqs usbcore.autosuspend=-1"

GRUB_D=/etc/default/grub.d
run install -d -m 0755 "$GRUB_D"
run tee "$GRUB_D/99-vstos.cfg" >/dev/null <<GRUBEOF
# Managed by VSTOS. Edit /etc/vstos/vstos.conf and re-run vstos-apply instead.
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

#!/usr/bin/env bash
# Build a bootable VSTOS installer ISO.
#
#   ./build/build-iso.sh                              download the base ISO, build
#   ./build/build-iso.sh --iso ubuntu-24.04.3-live-server-amd64.iso
#   ./build/build-iso.sh --password hunter2 --hostname foh-rack
#   ./build/build-iso.sh --fbk-release v0.1.0
#
# The result installs Ubuntu unattended and then runs provision/vstos-provision,
# which is the same code path as provisioning an existing machine. Nothing about
# how VSTOS is configured lives in the ISO: it clones this repository and runs it.
#
# Needs: xorriso, curl. No root, no loop mounts - xorriso reads and writes the
# image directly, which is also why this runs unchanged in CI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# The base image. Pinned to a point release rather than tracking "latest": an ISO
# builder whose output changes because someone else published something is not a
# builder, it is a surprise.
UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04.3}"
UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
UBUNTU_ISO="ubuntu-${UBUNTU_RELEASE}-live-server-${UBUNTU_ARCH}.iso"
UBUNTU_URL="${UBUNTU_URL:-https://releases.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_ISO}}"

VSTOS_REPO="${VSTOS_REPO:-https://github.com/adrianoftyriel/VSTOS.git}"
VSTOS_BRANCH="${VSTOS_BRANCH:-main}"
FBK_RELEASE="${FBK_RELEASE:-}"

HOSTNAME_="vstos"
ADMIN_USER="vstos"
ADMIN_PASSWORD=""
ADMIN_PASSWORD_HASH=""
LOCALE="en_GB.UTF-8"
KEYBOARD="gb"
SRC_ISO=""
OUT_ISO=""
KEEP_WORK=0

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "$0" | sed 's/^# \?//'; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --iso)           SRC_ISO="${2:?}"; shift ;;
        --out)           OUT_ISO="${2:?}"; shift ;;
        --hostname)      HOSTNAME_="${2:?}"; shift ;;
        --user)          ADMIN_USER="${2:?}"; shift ;;
        --password)      ADMIN_PASSWORD="${2:?}"; shift ;;
        --password-hash) ADMIN_PASSWORD_HASH="${2:?}"; shift ;;
        --locale)        LOCALE="${2:?}"; shift ;;
        --keyboard)      KEYBOARD="${2:?}"; shift ;;
        --repo)          VSTOS_REPO="${2:?}"; shift ;;
        --branch)        VSTOS_BRANCH="${2:?}"; shift ;;
        --fbk-release)   FBK_RELEASE="${2:?}"; shift ;;
        --keep-work)     KEEP_WORK=1 ;;
        --help|-h)       usage; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

command -v xorriso >/dev/null || die "xorriso is required (apt install xorriso)"
command -v curl    >/dev/null || die "curl is required"

WORK="$(mktemp -d)"
cleanup() { [ "$KEEP_WORK" = "1" ] || rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# The administrator account
# ---------------------------------------------------------------------------

hash_password() {
    if command -v openssl >/dev/null 2>&1; then
        openssl passwd -6 "$1"
    else
        # crypt is deprecated in 3.12 and gone in 3.13, so this is a fallback for
        # the fallback rather than the main path.
        python3 -c 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))' "$1"
    fi
}

if [ -z "$ADMIN_PASSWORD_HASH" ]; then
    if [ -z "$ADMIN_PASSWORD" ]; then
        # A generated password beats a default one. A default one ends up on every
        # box built from this script, on networks the builder does not control.
        ADMIN_PASSWORD="$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)"
        GENERATED=1
    fi
    ADMIN_PASSWORD_HASH="$(hash_password "$ADMIN_PASSWORD")"
fi
[ -n "$ADMIN_PASSWORD_HASH" ] || die "could not hash the administrator password"

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

if [ -z "$SRC_ISO" ]; then
    SRC_ISO="$ROOT/build/$UBUNTU_ISO"
    if [ -f "$SRC_ISO" ]; then
        log "using the cached base image at $SRC_ISO"
    else
        log "downloading $UBUNTU_ISO (about 3 GB)"
        curl -fL --progress-bar -o "$SRC_ISO.part" "$UBUNTU_URL" || die "download failed"
        mv "$SRC_ISO.part" "$SRC_ISO"
    fi

    # Verify against Canonical's published sums. Worth doing even over HTTPS: this
    # image is about to be installed unattended on machines that will sit on
    # networks the builder does not control, and a truncated download is common.
    if curl -fsSL -o "$WORK/SHA256SUMS" "https://releases.ubuntu.com/${UBUNTU_RELEASE}/SHA256SUMS"; then
        want="$(awk -v f="*$UBUNTU_ISO" '$2 == f { print $1 }' "$WORK/SHA256SUMS")"
        if [ -n "$want" ]; then
            log "verifying the base image"
            got="$(sha256sum "$SRC_ISO" | cut -d' ' -f1)"
            [ "$want" = "$got" ] || die "base image checksum mismatch (expected $want, got $got)"
            log "base image verified"
        else
            warn "$UBUNTU_ISO is not listed in SHA256SUMS; skipping verification"
        fi
    else
        warn "could not fetch SHA256SUMS; skipping verification of the base image"
    fi
fi

[ -f "$SRC_ISO" ] || die "no such ISO: $SRC_ISO"
OUT_ISO="${OUT_ISO:-$ROOT/build/vstos-${UBUNTU_RELEASE}-${UBUNTU_ARCH}.iso}"

# ---------------------------------------------------------------------------
# The autoinstall answers
# ---------------------------------------------------------------------------

log "rendering the autoinstall configuration"
python3 "$ROOT/provision/steps/render-template.py" \
    "$ROOT/build/autoinstall/user-data.tmpl" "$WORK/autoinstall.yaml" \
    "HOSTNAME=$HOSTNAME_" \
    "ADMIN_USER=$ADMIN_USER" \
    "ADMIN_PASSWORD_HASH=$ADMIN_PASSWORD_HASH" \
    "LOCALE=$LOCALE" \
    "KEYBOARD=$KEYBOARD" \
    "VSTOS_REPO=$VSTOS_REPO" \
    "VSTOS_BRANCH=$VSTOS_BRANCH" \
    "FBK_RELEASE=$FBK_RELEASE" \
    || die "could not render the autoinstall configuration"

# cloud-init's NoCloud datasource wants a meta-data file to exist, even empty.
: > "$WORK/meta-data"

# ---------------------------------------------------------------------------
# Boot menu
# ---------------------------------------------------------------------------

# Ubuntu has used GRUB for both BIOS and UEFI boot since 22.04, so there is one
# menu file to edit rather than a GRUB config and an isolinux config that can
# disagree with each other.
log "adding the autoinstall boot parameter"
xorriso -osirrox on -indev "$SRC_ISO" \
        -extract /boot/grub/grub.cfg "$WORK/grub.cfg" >/dev/null 2>&1 \
    || die "could not read /boot/grub/grub.cfg from the base image"

# `autoinstall` tells subiquity to look for /autoinstall.yaml on the ISO itself,
# so no network-served cloud-init seed is needed. ds=nocloud is what points
# cloud-init at the same place for its own metadata.
python3 "$ROOT/build/patch-grub-cfg.py" "$WORK/grub.cfg" \
    || die "could not add the autoinstall parameter to the boot menu"

# Default to the first entry with no wait, so an appliance being built in a rack
# with no keyboard installs itself.
sed -i 's/^set timeout=.*/set timeout=5/' "$WORK/grub.cfg" || true

# ---------------------------------------------------------------------------
# Repack
# ---------------------------------------------------------------------------

log "building $OUT_ISO"
rm -f "$OUT_ISO"

# `-boot_image any replay` copies the base image's boot arrangement - the BIOS
# boot record, the EFI system partition, the partition table offsets - rather than
# reconstructing it from a list of mkisofs flags that has to be kept in step with
# whatever Canonical changes next. Every file not named in a -map comes across
# unchanged.
xorriso -indev "$SRC_ISO" \
        -outdev "$OUT_ISO" \
        -boot_image any replay \
        -volid "VSTOS" \
        -compliance no_emul_toc \
        -map "$WORK/autoinstall.yaml" /autoinstall.yaml \
        -map "$WORK/meta-data" /meta-data \
        -map "$WORK/grub.cfg" /boot/grub/grub.cfg \
        -- >/dev/null 2>"$WORK/xorriso.log" || {
            cat "$WORK/xorriso.log" >&2
            die "xorriso failed"
        }

( cd "$(dirname "$OUT_ISO")" && sha256sum "$(basename "$OUT_ISO")" > "$(basename "$OUT_ISO").sha256" )

log "built $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
printf '\n'
printf '  hostname:   %s\n' "$HOSTNAME_"
printf '  admin user: %s\n' "$ADMIN_USER"
if [ "${GENERATED:-0}" = "1" ]; then
    printf '  password:   \033[1m%s\033[0m   <- generated; write this down, it is not stored\n' "$ADMIN_PASSWORD"
fi
printf '  provisions from: %s (%s)\n' "$VSTOS_REPO" "$VSTOS_BRANCH"
printf '\nWrite it to a USB stick and boot the target machine:\n'
printf '  sudo dd if=%s of=/dev/sdX bs=4M status=progress oflag=sync\n\n' "$OUT_ISO"
printf 'It will erase the disk it installs to, then reboot into the plugin host.\n'

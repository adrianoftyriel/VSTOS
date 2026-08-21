#!/usr/bin/env bash
# Build a VSTOS live USB image.
#
#   ./build/build-live-iso.sh                     24.04, into build/
#   ./build/build-live-iso.sh --ubuntu 26.04
#   ./build/build-live-iso.sh --iso ubuntu-24.04.4-live-server-amd64.iso
#
# The result runs entirely from the USB stick. It installs nothing, and it never
# writes to, partitions, or even mounts an internal disk - there is no installer
# on the image to do so. Write it with build/vstos-usb-write.sh to get a
# persistence partition alongside it, so racks and configuration survive a reboot.
#
# This is a different thing from build/build-iso.sh, which builds an *installer*
# that puts VSTOS onto a disk. If you want a machine that boots off a stick and
# leaves the hardware alone, this is the one.
#
# How it works: unpack the Ubuntu Server live ISO, throw away its installer layer,
# run the ordinary VSTOS provisioner inside the resulting root filesystem, squash
# it back up, and boot that with casper. The provisioner is the same code that
# provisions a real machine, so a live stick and an installed box are the same
# system.
#
# Needs: xorriso, squashfs-tools, rsync, and root (it chroots). About 20 GB free.
set -euo pipefail

trap 'printf "\nbuild-live-iso.sh: failed at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-24.04.4}"
UBUNTU_ARCH="${UBUNTU_ARCH:-amd64}"
FBK_RELEASE="${FBK_RELEASE:-}"
SRC_ISO=""
OUT_ISO=""
KEEP_WORK=0

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ubuntu)      UBUNTU_RELEASE="${2:?}"; shift ;;
        --iso)         SRC_ISO="${2:?}"; shift ;;
        --out)         OUT_ISO="${2:?}"; shift ;;
        --fbk-release) FBK_RELEASE="${2:?}"; shift ;;
        --keep-work)   KEEP_WORK=1 ;;
        --help|-h)     sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
    shift
done

case "$UBUNTU_RELEASE" in
    24.04*|26.04*) ;;
    *) die "Ubuntu $UBUNTU_RELEASE is not a release VSTOS provisions (24.04 or 26.04)" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root: this unpacks and chroots into a root filesystem"
for t in xorriso unsquashfs mksquashfs rsync sfdisk sgdisk; do
    command -v "$t" >/dev/null || die "$t is required (apt install xorriso squashfs-tools rsync fdisk gdisk)"
done

UBUNTU_ISO="ubuntu-${UBUNTU_RELEASE}-live-server-${UBUNTU_ARCH}.iso"
UBUNTU_URL="${UBUNTU_URL:-https://releases.ubuntu.com/${UBUNTU_RELEASE}/${UBUNTU_ISO}}"
OUT_ISO="${OUT_ISO:-$ROOT/build/vstos-live-${UBUNTU_RELEASE}-${UBUNTU_ARCH}.iso}"

WORK="$(mktemp -d -p "${VSTOS_WORK_PARENT:-/var/tmp}" vstos-live.XXXXXX)"
ISO_DIR="$WORK/iso"
ROOTFS="$WORK/rootfs"

cleanup() {
    # Unmount before removing, or rm -rf walks into /proc and /dev on the host.
    for m in dev/pts dev proc sys run; do
        mountpoint -q "$ROOTFS/$m" 2>/dev/null && umount -lf "$ROOTFS/$m" 2>/dev/null || true
    done
    mountpoint -q "$WORK/merged" 2>/dev/null && umount -lf "$WORK/merged" 2>/dev/null || true
    for d in "$WORK"/l[0-9]*; do
        mountpoint -q "$d" 2>/dev/null && umount -lf "$d" 2>/dev/null || true
    done
    [ "$KEEP_WORK" = "1" ] || rm -rf "$WORK"
}
trap cleanup EXIT

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
    if curl -fsSL -o "$WORK/SHA256SUMS" "https://releases.ubuntu.com/${UBUNTU_RELEASE}/SHA256SUMS"; then
        want="$(awk -v f="*$UBUNTU_ISO" '$2 == f { print $1; exit }' "$WORK/SHA256SUMS")"
        if [ -n "$want" ]; then
            log "verifying the base image"
            got="$(sha256sum "$SRC_ISO" | cut -d' ' -f1)"
            [ "$want" = "$got" ] || die "base image checksum mismatch"
        fi
    else
        warn "could not fetch SHA256SUMS; not verifying the base image"
    fi
fi
[ -f "$SRC_ISO" ] || die "no such ISO: $SRC_ISO"

# ---------------------------------------------------------------------------
# Unpack
# ---------------------------------------------------------------------------

log "unpacking the base image"
mkdir -p "$ISO_DIR"
xorriso -osirrox on -indev "$SRC_ISO" -extract / "$ISO_DIR" >/dev/null 2>&1 \
    || die "could not extract $SRC_ISO"
chmod -R u+w "$ISO_DIR"

[ -d "$ISO_DIR/casper" ] || die "no casper directory: is $SRC_ISO an Ubuntu live image?"

# The server ISO ships its root filesystem as stacked squashfs layers - a minimal
# base, the server layer on top of it, and the installer on top of that. Stacking
# them in order gives the same filesystem the live session would see.
#
# The installer layer is deliberately dropped. It is what carries subiquity, and
# subiquity is the thing that erases disks. An image with no installer in it
# cannot install to anything by accident.
mapfile -t LAYERS < <(find "$ISO_DIR/casper" -maxdepth 1 -name '*.squashfs' -printf '%f\n' \
    | grep -v 'installer' | sort)
[ "${#LAYERS[@]}" -gt 0 ] || die "no usable squashfs layers found in casper/"

log "root filesystem layers: ${LAYERS[*]}"

# Stack them with overlayfs rather than unpacking them one on top of another.
#
# These are not independent trees: the upper layers are deltas, and a delta says
# both "here are some files" and "here are some files the layer underneath had
# that should now be gone", the latter as overlayfs whiteouts. unsquashfs into a
# populated directory gets this wrong twice over - it fails outright on hardlinks
# that already exist, and it would materialise whiteout entries as real files.
# Mounting them the way casper does and copying out the merged view is the only
# way to get the filesystem the live session would actually see.
mkdir -p "$WORK/merged"
LOWERS=""
for i in "${!LAYERS[@]}"; do
    mkdir -p "$WORK/l$i"
    mount -t squashfs -o loop,ro "$ISO_DIR/casper/${LAYERS[$i]}" "$WORK/l$i" \
        || die "could not mount ${LAYERS[$i]}"
    # lowerdir is highest-priority-first, and LAYERS is sorted lowest-first, so
    # each new layer goes on the front.
    LOWERS="$WORK/l$i${LOWERS:+:$LOWERS}"
done

mount -t overlay overlay -o "lowerdir=$LOWERS" "$WORK/merged" \
    || die "could not stack the root filesystem layers"

log "copying out the merged root filesystem"
mkdir -p "$ROOTFS"
# -H keeps hardlinks (the base image is full of them), -A and -X keep ACLs and
# xattrs, which is what carries file capabilities such as ping's.
rsync -aHAX --numeric-ids "$WORK/merged/" "$ROOTFS/" || die "could not copy the root filesystem"

umount "$WORK/merged"
for i in "${!LAYERS[@]}"; do umount "$WORK/l$i" 2>/dev/null || true; done

# ---------------------------------------------------------------------------
# Provision, inside the root filesystem
# ---------------------------------------------------------------------------

log "installing VSTOS into the root filesystem"
mkdir -p "$ROOTFS/usr/share/vstos/src"
rsync -a --exclude '.git' --exclude 'build/*.iso*' \
    "$ROOT/provision" "$ROOT/system" "$ROOT/build" "$ROOT/docs" \
    "$ROOT/README.md" "$ROOT/LICENSE" "$ROOT/VERSION" "$ROOTFS/usr/share/vstos/src/"

cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
mount --bind /dev     "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc    "$ROOTFS/proc"
mount -t sysfs sys    "$ROOTFS/sys"

# casper is what makes the thing bootable as a live system: its initramfs hooks
# build the overlay and find the persistence partition. It is in the installer
# layer we just discarded, so it has to be put back explicitly.
cat > "$ROOTFS/tmp/vstos-chroot.sh" <<'CHROOTEOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Drop the ISO's own package pool from apt's sources before touching apt.
#
# The live filesystem is built to be installed from the CD, so it carries a
# source pointing at file:/cdrom - the pool on the ISO itself. Inside this chroot
# there is no /cdrom, so `apt-get update` fails with
#
#   E: The repository 'file:/cdrom <suite> Release' does not have a Release file.
#
# and under `set -e` that ends the chroot script, which surfaces as the useless
# "provisioning inside the root filesystem failed". 26.04 ships this source where
# 24.04 did not, so the builder worked on one release and not the other.
#
# Removing it rather than bind-mounting the ISO at /cdrom is deliberate: this
# build wants packages from the network archive, at their current versions, not
# whatever was frozen onto the installer image.
#
# Both source formats, because the archive is mid-migration from one to the
# other: deb822 stanzas in *.sources, and one-line entries in *.list.
for f in /etc/apt/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    awk 'BEGIN{RS="";ORS="\n\n"} !/URIs:[ \t]*(file|cdrom):/' "$f" > "$f.vstos-tmp" \
        && mv "$f.vstos-tmp" "$f"
done
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sed -i -E '/^[[:space:]]*deb(-src)?[[:space:]]+(\[[^]]*\][[:space:]]+)?(file|cdrom):/d' "$f"
done

# If that left apt with nothing to talk to - possible if the image's only source
# was the CD - put the archive back. Better to state the sources outright than to
# fail later with an empty package list and no obvious cause.
CODENAME="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"
if ! grep -rhsqE '^(URIs:[[:space:]]*https?:|deb[[:space:]]+(\[[^]]*\][[:space:]]+)?https?:)' \
        /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    printf 'vstos: no network apt source survived; writing one for %s\n' "$CODENAME" >&2
    printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: %s %s-updates %s-security\nComponents: main universe restricted multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
        "$CODENAME" "$CODENAME" "$CODENAME" > /etc/apt/sources.list.d/ubuntu.sources
fi

# The base image ships without backports enabled, and lsp-plugins-vst3 - the
# VST3 build of the largest suite in the library - lives there on 24.04. Without
# this the plugin step falls back to installing one package at a time and quietly
# skips it, and the live image ends up with a smaller library than an installed
# machine gets.
if [ -f /etc/apt/sources.list.d/ubuntu.sources ] && ! grep -q -- "-backports" /etc/apt/sources.list.d/ubuntu.sources; then
    printf '\nTypes: deb\nURIs: http://archive.ubuntu.com/ubuntu/\nSuites: %s-backports\nComponents: main universe restricted multiverse\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' \
        "$CODENAME" >> /etc/apt/sources.list.d/ubuntu.sources
elif [ -f /etc/apt/sources.list ] && ! grep -q -- "-backports" /etc/apt/sources.list; then
    printf '\ndeb http://archive.ubuntu.com/ubuntu/ %s-backports main universe restricted multiverse\n' \
        "$CODENAME" >> /etc/apt/sources.list
fi

if ! apt-get update -qq; then
    printf '\nvstos: apt-get update failed inside the chroot. Sources in effect:\n' >&2
    grep -rhsE '^(Types|URIs|Suites|deb)' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null >&2
    exit 1
fi

# casper for the live boot, and the kernel the provisioner is about to install
# needs an initramfs that contains casper's hooks.
apt-get install -y -qq --no-install-recommends casper initramfs-tools

# The ordinary provisioner. Same code as a real install; VSTOS_FORCE_NO_SYSTEMD
# because there is no init running in here to talk to.
VSTOS_FORCE_NO_SYSTEMD=1 FBK_RELEASE="${FBK_RELEASE:-}" \
    /usr/share/vstos/src/provision/vstos-provision

# Nothing in a live image should try to install anything.
apt-get purge -y -qq subiquity ubuntu-desktop-installer 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/subiquity*.service 2>/dev/null || true

# The live user casper logs in as. The session runs as the VSTOS audio user under
# systemd, so this account exists only so casper has something to hand a console
# to if somebody plugs a keyboard in.
if ! getent passwd vstos >/dev/null; then
    useradd -m -s /bin/bash -G sudo,audio,video,input vstos
    passwd -d vstos
fi

# Regenerate the initramfs for every kernel present, so casper's hooks are in it.
for kver in $(ls /lib/modules 2>/dev/null); do
    [ -f "/boot/vmlinuz-$kver" ] || continue
    update-initramfs -c -k "$kver" >/dev/null 2>&1 || update-initramfs -u -k "$kver" >/dev/null 2>&1 || true
done

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOTEOF
chmod +x "$ROOTFS/tmp/vstos-chroot.sh"

FBK_RELEASE="$FBK_RELEASE" chroot "$ROOTFS" /tmp/vstos-chroot.sh \
    || die "provisioning inside the root filesystem failed"
rm -f "$ROOTFS/tmp/vstos-chroot.sh"

# ---------------------------------------------------------------------------
# The kernel the stick will actually boot
# ---------------------------------------------------------------------------

# This is the step that makes it a VSTOS image rather than Ubuntu's kernel with
# VSTOS files on it. casper boots /casper/vmlinuz from the ISO, not whatever is
# inside the squashfs - so the low-latency kernel the provisioner just installed
# has to be lifted out and put where the boot loader looks.
# Report what the image actually contains before it is sealed into a squashfs,
# because after that it is a 1.5 GB blob and nobody is going to check.
if [ -e "$ROOTFS/usr/lib/vst3/FBKSuppressor.vst3" ]; then
    log "FBKSuppressor $(cat "$ROOTFS/usr/lib/vstos/fbksuppressor.version" 2>/dev/null || echo installed) is in the image"
else
    warn "FBKSuppressor is NOT in this image - the download failed during the build"
    warn "the rest of VSTOS is fine; run vstos-install-fbksuppressor on the booted stick"
fi
log "plugin library in the image: $(find "$ROOTFS/usr/lib/lv2" -maxdepth 1 -name '*.lv2' 2>/dev/null | wc -l) LV2, $(find "$ROOTFS/usr/lib/vst3" -maxdepth 1 -name '*.vst3' 2>/dev/null | wc -l) VST3"

# /lib is a symlink to /usr/lib on a merged-usr system, but not every image is
# merged, so look in both. Globs rather than parsing ls.
KVER=""
for d in "$ROOTFS"/usr/lib/modules/* "$ROOTFS"/lib/modules/*; do
    [ -d "$d" ] || continue
    v="$(basename "$d")"
    [ -z "$KVER" ] && KVER="$v"
    [ "$(printf '%s\n%s\n' "$KVER" "$v" | sort -V | tail -1)" = "$v" ] && KVER="$v"
done
[ -n "$KVER" ] || die "no kernel found in the root filesystem"

if [ -f "$ROOTFS/boot/vmlinuz-$KVER" ] && [ -f "$ROOTFS/boot/initrd.img-$KVER" ]; then
    log "booting kernel $KVER from the image"
    cp "$ROOTFS/boot/vmlinuz-$KVER" "$ISO_DIR/casper/vmlinuz"
    cp "$ROOTFS/boot/initrd.img-$KVER" "$ISO_DIR/casper/initrd"
else
    warn "no initramfs for $KVER; keeping the base image's kernel"
fi

umount -lf "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/proc" "$ROOTFS/sys" 2>/dev/null || true
rm -f "$ROOTFS/etc/resolv.conf"

# ---------------------------------------------------------------------------
# Repack the filesystem
# ---------------------------------------------------------------------------

log "squashing the root filesystem (this is the slow part)"
# Everything the base image had in casper goes: its squashfs layers, its spare
# HWE kernel pair (about 100 MB that nothing in our boot menu references), and
# the installer's source list. What we put back is our filesystem and our kernel.
rm -f "$ISO_DIR"/casper/*.squashfs "$ISO_DIR"/casper/*.squashfs.gpg \
      "$ISO_DIR"/casper/*.manifest "$ISO_DIR"/casper/*.size \
      "$ISO_DIR"/casper/hwe-vmlinuz "$ISO_DIR"/casper/hwe-initrd \
      "$ISO_DIR"/casper/install-sources.yaml 2>/dev/null || true

mksquashfs "$ROOTFS" "$ISO_DIR/casper/filesystem.squashfs" \
    -comp zstd -Xcompression-level 15 -no-progress -noappend \
    || die "mksquashfs failed"

printf '%s' "$(du -sx --block-size=1 "$ROOTFS" | cut -f1)" > "$ISO_DIR/casper/filesystem.size"
chroot "$ROOTFS" dpkg-query -W --showformat='${Package} ${Version}\n' \
    > "$ISO_DIR/casper/filesystem.manifest" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Boot menu
# ---------------------------------------------------------------------------

# A live system has no /etc/default/grub that matters: the boot loader is on the
# stick and its configuration is fixed here, at build time. So every kernel
# parameter VSTOS wants has to be on this line.
CMDLINE="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$ROOT/system/kernel-cmdline" | tr '\n' ' ')"
CMDLINE="$(printf '%s' "$CMDLINE" | sed -e 's/[[:space:]]\+/ /g' -e 's/^ //' -e 's/ $//')"

log "boot parameters: boot=casper persistent $CMDLINE"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<GRUBEOF
# VSTOS live. Generated by build/build-live-iso.sh - edit that, not this.
set default=0
set timeout=3
set timeout_style=menu

menuentry "VSTOS (live, persistent)" {
    linux /casper/vmlinuz boot=casper persistent quiet $CMDLINE ---
    initrd /casper/initrd
}

menuentry "VSTOS (live, no persistence)" {
    linux /casper/vmlinuz boot=casper quiet $CMDLINE ---
    initrd /casper/initrd
}

menuentry "VSTOS (live, verbose - show boot messages)" {
    linux /casper/vmlinuz boot=casper persistent $CMDLINE ---
    initrd /casper/initrd
}
GRUBEOF

# The installer's own answer files must not survive into a live image; there is
# nothing here for them to drive, and leaving them would be misleading.
rm -f "$ISO_DIR/autoinstall.yaml" "$ISO_DIR/meta-data" "$ISO_DIR/user-data" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Repack the ISO
# ---------------------------------------------------------------------------

log "building $OUT_ISO"
rm -f "$OUT_ISO"

# One xorriso pass, not two, and that is the whole point.
#
# This was previously done as: write the image with /casper removed, then reopen
# it and add the new /casper back. The partition table is computed when the image
# is written, so it described the intermediate state - the ISO *without* the
# squashfs. Adding 1.5 GB of casper afterwards grew the image without touching
# the table, leaving a GPT that claimed the disk ended at 1.2 GB when it ended at
# 3.2 GB.
#
# On a stick that is not cosmetic. The ISO9660 data extends past the end of its
# own declared partition, and the persistence partition the writer appends lands
# in territory the table does not account for, so casper's mount of casper-rw
# fails with "Device or resource busy" and the boot stops in the initramfs.
#
# Removing and re-adding in a single pass means the geometry is computed once,
# against the finished content.
xorriso -indev "$SRC_ISO" -outdev "$OUT_ISO" \
        -boot_image any replay \
        -volid "VSTOS_LIVE" \
        -compliance no_emul_toc \
        -rm_r /casper -- \
        -map "$ISO_DIR/casper" /casper \
        -map "$ISO_DIR/boot/grub/grub.cfg" /boot/grub/grub.cfg \
        -- >/dev/null 2>"$WORK/x1.log" || { cat "$WORK/x1.log" >&2; die "xorriso failed"; }

# The source ISO carries a third 600-sector partition that `replay` does not
# reproduce, which leaves the backup GPT a little short of the end. sgdisk -e
# relocates it, and the result is a table with no inconsistency at all.
if command -v sgdisk >/dev/null 2>&1; then
    sgdisk -e "$OUT_ISO" >/dev/null 2>&1 || true
fi

# Refuse to ship an image whose partition table disagrees with its own size -
# the exact defect above, caught before anyone writes it to a stick.
if command -v sfdisk >/dev/null 2>&1; then
    if sfdisk -l "$OUT_ISO" 2>&1 | grep -qE "PMBR size mismatch|backup GPT table is not"; then
        sfdisk -l "$OUT_ISO" 2>&1 | grep -E "PMBR size mismatch|backup GPT table is not" >&2
        die "the built image has an inconsistent partition table; it would not boot reliably"
    fi
    log "partition table is consistent with the image"
fi

( cd "$(dirname "$OUT_ISO")" && sha256sum "$(basename "$OUT_ISO")" > "$(basename "$OUT_ISO").sha256" )

log "built $OUT_ISO ($(du -h "$OUT_ISO" | cut -f1))"
printf '\n'
printf '  This image installs nothing and never touches an internal disk.\n'
printf '  Write it to a stick with persistence:\n\n'
printf '    sudo ./build/vstos-usb-write.sh %s /dev/sdX\n\n' "$OUT_ISO"

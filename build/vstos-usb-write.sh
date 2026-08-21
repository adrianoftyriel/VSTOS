#!/usr/bin/env bash
# Write a VSTOS live image to a USB stick, with persistence.
#
#   sudo ./build/vstos-usb-write.sh vstos-live-24.04.4-amd64.iso /dev/sdX
#   sudo ./build/vstos-usb-write.sh --list
#
# The ISO on its own boots read-only: every change is lost at power-off. This
# writes the image and then adds a `casper-rw` partition in the space left over,
# which casper picks up automatically because the image boots with `persistent`.
# Saved racks, /etc/vstos/vstos.conf and anything else written then survive.
#
# It refuses to write to anything that is not removable unless forced. Getting
# this wrong costs somebody their hard drive, which has happened once already on
# this project and is not going to happen again through this script.
set -euo pipefail

trap 'printf "\nvstos-usb-write.sh: failed at line %s (exit %s)\n" "$LINENO" "$?" >&2' ERR

FORCE=0
log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

list_removable() {
    printf 'Removable block devices:\n'
    local found=0 dev name size rm_flag
    for dev in /sys/block/*; do
        name="$(basename "$dev")"
        case "$name" in loop*|ram*|dm-*|sr*) continue ;; esac
        rm_flag="$(cat "$dev/removable" 2>/dev/null || echo 0)"
        size="$(cat "$dev/size" 2>/dev/null || echo 0)"
        [ "$rm_flag" = "1" ] || continue
        found=1
        printf '  /dev/%-8s %6s GB  %s\n' "$name" \
            "$(( size * 512 / 1000000000 ))" \
            "$(cat "$dev/device/model" 2>/dev/null | tr -d '\n' || echo '?')"
    done
    [ "$found" = 1 ] || printf '  (none found)\n'
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --list) list_removable; exit 0 ;;
        --force) FORCE=1 ;;
        --help|-h) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) break ;;
    esac
    shift
done

ISO="${1:-}"
DEV="${2:-}"
[ -n "$ISO" ] && [ -n "$DEV" ] || { sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 2; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$ISO" ] || die "no such image: $ISO"
[ -b "$DEV" ] || die "not a block device: $DEV"

for t in sfdisk sgdisk mkfs.ext4 partprobe; do
    command -v "$t" >/dev/null || die "$t is required (apt install fdisk gdisk e2fsprogs parted)"
done

NAME="$(basename "$DEV")"
REMOVABLE="$(cat "/sys/block/$NAME/removable" 2>/dev/null || echo 0)"
SIZE_B=$(( $(cat "/sys/block/$NAME/size") * 512 ))
MODEL="$(cat "/sys/block/$NAME/device/model" 2>/dev/null | tr -d '\n' || echo '?')"

if [ "$REMOVABLE" != "1" ] && [ "$FORCE" != "1" ]; then
    printf '\n' >&2
    printf 'refusing: %s is not a removable device.\n' "$DEV" >&2
    printf '  model: %s\n  size:  %s GB\n\n' "$MODEL" "$(( SIZE_B / 1000000000 ))" >&2
    printf 'This is almost certainly an internal drive. Run --list to see what is\n' >&2
    printf 'removable. Pass --force only if you are certain.\n' >&2
    exit 1
fi

# Mounted partitions of the target are a sign it is in use - possibly the system
# you are running from.
if lsblk -nro MOUNTPOINT "$DEV" 2>/dev/null | grep -q .; then
    die "$DEV has mounted partitions; unmount them first (and check it is the right device)"
fi

ISO_B=$(stat -c %s "$ISO")
[ "$SIZE_B" -gt "$ISO_B" ] || die "$DEV ($(( SIZE_B / 1000000000 )) GB) is smaller than the image"

printf '\n\033[1mAbout to erase %s\033[0m\n' "$DEV"
printf '  model:     %s\n' "$MODEL"
printf '  size:      %s GB\n' "$(( SIZE_B / 1000000000 ))"
printf '  image:     %s (%s)\n' "$ISO" "$(du -h "$ISO" | cut -f1)"
printf '  after it:  a casper-rw persistence partition filling the rest\n\n'
printf 'Type the device name to confirm (%s): ' "$DEV"
read -r confirm
[ "$confirm" = "$DEV" ] || die "not confirmed; nothing was written"

log "writing the image"
dd if="$ISO" of="$DEV" bs=4M status=progress oflag=sync conv=fsync

# The image was written onto a stick that is larger than it, so the GPT's backup
# copy is sitting wherever the image ended rather than at the end of the device,
# and the table still describes a disk the size of the image. Relocate it before
# adding anything, or the appended partition lands outside what the table
# believes exists - which is how casper ends up unable to mount casper-rw and the
# boot stops in the initramfs with "Device or resource busy".
log "moving the backup GPT to the end of the device"
sgdisk -e "$DEV" >/dev/null 2>&1 || die "could not relocate the backup GPT on $DEV"
partprobe "$DEV" 2>/dev/null || true
sleep 1

log "adding the persistence partition"
# Start after the last partition the table actually declares, rather than after
# the image file's size. Those are not the same number once sgdisk has tidied up,
# and the table is the thing the kernel and casper both read.
LAST_END=$(sfdisk -d "$DEV" 2>/dev/null | awk -F'[ ,=]+' '/start=/ {for(i=1;i<=NF;i++){if($i=="start")st=$(i+1); if($i=="size")sz=$(i+1)}; e=st+sz; if(e>m)m=e} END{print m+0}')
[ "${LAST_END:-0}" -gt 0 ] || die "could not read the partition table on $DEV"
START_SECTOR=$(( (LAST_END + 2047) / 2048 * 2048 ))   # 1 MiB aligned
printf '%s,,L\n' "$START_SECTOR" | sfdisk --append --no-reread "$DEV" >/dev/null \
    || die "could not append a persistence partition (the stick may be too small)"

partprobe "$DEV" 2>/dev/null || true
sleep 2

PART="$(lsblk -nro NAME "$DEV" | tail -1)"
PART="/dev/$PART"
[ -b "$PART" ] || die "the new partition did not appear as expected"

log "formatting $PART as casper-rw"
mkfs.ext4 -F -L casper-rw "$PART" >/dev/null || die "could not format $PART"

sync
log "done"
printf '\n'
printf '  %s is now a VSTOS live stick with persistence.\n' "$DEV"
printf '  Boot the target machine from it. It installs nothing and does not\n'
printf '  touch the internal drive.\n\n'
printf '  First boot: vstos-status\n'

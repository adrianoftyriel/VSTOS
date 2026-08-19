#!/usr/bin/env python3
"""Add the autoinstall boot parameters to an Ubuntu live ISO's GRUB menu.

    patch-grub-cfg.py /path/to/grub.cfg

`autoinstall` tells subiquity to install without asking; `ds=nocloud;s=/cdrom/`
points cloud-init at the ISO itself, which is where build-iso.sh puts
autoinstall.yaml. The semicolon is escaped because GRUB treats a bare one as a
command separator.

Every kernel line is patched, not just the first. Ubuntu's menu carries separate
entries - the default kernel, the hardware-enablement kernel, safe graphics - and
a machine whose operator picks any entry but the first would otherwise sit at an
interactive installer waiting for a keyboard that, on an appliance being built
into a rack, is not there.

Idempotent: a line that already mentions autoinstall is left alone.
"""
import pathlib
import re
import sys

PARAMS = r"autoinstall ds=nocloud\;s=/cdrom/"

# Any kernel line pointing into /casper, whatever the image is called. Matching
# the literal /casper/vmlinuz would miss /casper/hwe-vmlinuz.
KERNEL_LINE = re.compile(r"(?m)^\s*linux(?:16|efi)?\s+\S*/casper/\S*vmlinuz\S*.*$")


def patch_line(line):
    if "autoinstall" in line:
        return line
    # Ubuntu ends its kernel lines with " ---", which separates installer
    # arguments from kernel ones. Keep the parameters on the installer side of it
    # when it is there, and just append when it is not.
    if " ---" in line:
        return line.replace(" ---", " " + PARAMS + " ---", 1)
    return line.rstrip() + " " + PARAMS


def main(argv):
    if len(argv) != 2:
        sys.stderr.write(__doc__)
        return 2

    path = pathlib.Path(argv[1])
    text = path.read_text()
    patched, count = KERNEL_LINE.subn(lambda m: patch_line(m.group(0)), text)

    if count == 0:
        sys.stderr.write("patch-grub-cfg: no /casper kernel lines found in %s\n" % path)
        return 3

    path.write_text(patched)
    sys.stderr.write("patch-grub-cfg: patched %d kernel line(s)\n" % count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

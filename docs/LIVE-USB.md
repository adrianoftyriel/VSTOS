# The live USB

The way to run VSTOS on hardware you care about. The stick is the whole system:
it boots, runs and saves to itself, and the machine's own drives are never
touched — not partitioned, not written to, not mounted.

---

## Building and writing it

```sh
sudo ./build/build-live-iso.sh                    # ~20 min, needs ~20 GB free
sudo ./build/vstos-usb-write.sh --list            # which device is the stick?
sudo ./build/vstos-usb-write.sh build/vstos-live-24.04.4-amd64.iso /dev/sdX
```

`--ubuntu 26.04` builds on 26.04 instead.

The writer refuses any device that is not removable unless you pass `--force`,
and makes you type the device name back before it writes anything. Use `--list`
rather than guessing: `/dev/sda` is the internal disk on most machines.

Use a stick with room to spare. The image is around 3 GB and everything left over
becomes persistence.

---

## What "live" means here, precisely

The stick carries a read-only squashfs of a fully provisioned VSTOS, plus a
`casper-rw` partition. At boot, casper stacks a writable overlay on top of the
squashfs and backs it with that partition. So:

- **Everything works normally.** Saving a rack, editing
  `/etc/vstos/vstos.conf`, `apt install` — these all behave as they would on an
  installed system.
- **Changes survive a reboot**, because the overlay is on the stick.
- **Nothing is ever written to an internal disk.** There is no installer on the
  image; the build deliberately discards the ISO's installer layer.

The boot menu offers a no-persistence entry as well, which is useful when you
want a known-good state: it boots the same image and throws away every change at
power-off.

---

## The kernel

A live system has no `/etc/default/grub` that matters — the boot loader lives on
the stick and its configuration is fixed when the image is built. So the tuning
that an installed machine gets from `lowlatency-kernel` and from VSTOS's own GRUB
snippet is baked into the image's boot menu instead:

```
boot=casper persistent quiet preempt=full rcu_nocbs=all threadirqs usbcore.autosuspend=-1
```

That list lives in `system/kernel-cmdline`, and both the installed path and the
live image read it, so they cannot drift apart.

The kernel itself is the low-latency one the provisioner installs, not the one
Ubuntu's ISO shipped with. The build lifts `vmlinuz` and a freshly generated
initramfs out of the provisioned filesystem and boots those — otherwise the stick
would run Ubuntu's generic kernel with VSTOS merely installed alongside it.

---

## Persistence, and what to do when it fills up

The persistence partition is whatever space was left on the stick. Check it:

```sh
df -h /cow          # casper mounts the writable layer here
```

It holds your racks, your configuration and anything you install. If it fills,
the system keeps running but writes start failing, which looks like a host that
will not save. Clearing the package cache usually recovers plenty:

```sh
sudo apt clean
sudo journalctl --vacuum-size=100M
```

Back up what matters off the stick, because a USB stick is a consumable:

```sh
scp vstos@vstos.local:/var/lib/vstos/projects/*.carxp ./
```

---

## Cloning a stick that works

Once a stick is set up the way you want it, the quickest way to a second one is
to copy the whole device:

```sh
sudo dd if=/dev/sdX of=vstos-stick.img bs=4M status=progress
sudo dd if=vstos-stick.img of=/dev/sdY bs=4M status=progress oflag=sync
```

Both sticks must be the same size or the target larger. This copies your racks
and configuration with it, which is usually what you want for a second rig.

---

## When to use the installer instead

`build/build-iso.sh` builds an installer that puts VSTOS permanently onto a disk.
It is the right choice for a dedicated machine that will never be anything else —
a rack-mounted box with an SSD in it. It is the wrong choice for a laptop you also
use for something else.

It erases the disk it installs to. It will stop and ask which one unless you name
it with `--target-disk`, and it will not choose for you. That safeguard exists
because an earlier version did choose, picked an internal drive, and destroyed
what was on it.

---

## From a Windows PC

Two different questions, with two different answers.

### Writing the stick: yes

Use **[Rufus](https://rufus.ie)**. It has built-in persistence support for
Ubuntu-based images since 3.7, and what it creates is the same `casper-rw`
partition `vstos-usb-write.sh` makes on Linux — so a stick written from Windows
behaves identically, saved racks and all.

1. Open Rufus and pick the USB stick under **Device**.
2. **Boot selection** → SELECT → the `vstos-live-*.iso`.
3. Set **Persistent partition size** to a few GB. This is the step that matters:
   leave it at 0 and the stick boots fine but forgets everything at power-off,
   which on this machine means losing your saved rack.
4. **Partition scheme**: GPT for a UEFI machine, MBR for an old BIOS one.
5. START, and accept "Write in DD Image mode" if it asks.

balenaEtcher and Ventoy write the image too, but neither creates the persistence
partition, so the rig comes up read-only-ish every boot. Rufus is the one to use.

### Building the image: no, not on Windows itself

`build-live-iso.sh` needs root, `chroot`, an overlayfs mount, loop-mounted
squashfs and about 20 GB — a Linux machine, and a permissive one. Native Windows
cannot do any of that, and this is not something a bit of porting would fix.

You have three ways round it, best first:

1. **Download one CI built.** Actions → **ISO** workflow → Run workflow, then take
   `vstos-live-iso` from the finished run's artifacts. No Linux anywhere in the
   process, and the image is built from the same commit as everything else.
2. **WSL2.** Plausible but untested by this project — WSL2 has a real kernel and
   generally supports loop devices and overlayfs, but it is not a guarantee, and
   a half-finished chroot is an unpleasant thing to debug. If you try it, run
   `sudo ./build/build-live-iso.sh` and it will tell you what is missing.
3. **A Linux box or VM.** Any Ubuntu machine with 20 GB free.

Whichever way the image is produced, writing it to the stick is Rufus's job.

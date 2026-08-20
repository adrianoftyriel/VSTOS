# VSTOS

An Ubuntu-based operating system that does one thing: boot a machine into a plugin
host wired to a Behringer WING over USB, on the low-latency kernel, with no
desktop in the way.

Power it on and about twenty seconds later the console has forty-eight channels of
plugin processing available as inserts. There is no login, no desktop, no file
manager, and nothing to click before audio passes.

---

## What it is

| | |
|---|---|
| **Base** | Ubuntu Server **24.04 LTS or 26.04 LTS**, no desktop. Both tested in CI |
| **Kernel** | Kernel 7.0 with `preempt=full rcu_nocbs=all threadirqs` — see [below](#about-the-low-latency-kernel) |
| **Engine** | JACK2 directly on ALSA, 48 kHz, 128×3 frames by default |
| **Host** | Carla — LADSPA, DSSI, LV2, VST2, VST3 and SFZ, with a JACK patchbay |
| **Session** | A bare X server with one fullscreen client, or fully headless |
| **Console** | Behringer WING, 48×48 channels, USB Audio Class 2, no driver needed |
| **Plugins** | 545 LV2 plugins on 24.04, 520 on 26.04, plus 23 VST3 bundles |
| **FBKSuppressor** | Installed as VST3 and loaded into the boot rack |

Two ways to get it:

```sh
# 1. Build an installer ISO and boot it. Erases the target disk, then reboots
#    into the plugin host with nothing to answer.
./build/build-iso.sh                  # 24.04 LTS (default)
./build/build-iso.sh --ubuntu 26.04   # 26.04 LTS

# 2. Or turn an existing minimal Ubuntu Server install into VSTOS. Works on
#    either release; the provisioner detects which and adjusts.
sudo ./provision/vstos-provision
```

Both run exactly the same code. The ISO is the provisioner with a partitioner in
front of it.

---

## The rack it boots into

FBKSuppressor is a **mono insert**: one input, one output, and a sidechain input
reserved for feeding it the PA send. VSTOS wires it across a single pair of USB
channels, so on the console it behaves like a piece of outboard on an insert
point — send on USB 1, return on USB 1.

```
WING channel 1  ──USB send 1──▶  FBKSuppressor  ──USB return 1──▶  WING channel 1
```

Change which channel in `/etc/vstos/vstos.conf` (`INSERT_CHANNEL`), then
`vstos-apply`. Adding more instances, and saving your own rack over the shipped
one, is two commands in [docs/OPERATING.md](docs/OPERATING.md).

---

## About the low-latency kernel

Worth being precise, because the package named `linux-lowlatency` no longer
contains a low-latency kernel.

It used to be a separate flavour — a distinct image built with `CONFIG_PREEMPT`
and a 1000 Hz tick. What replaced it is the **generic kernel plus boot-time
tuning**: the generic kernel is now `PREEMPT_DYNAMIC`, so its preemption model is
a boot parameter rather than a compile-time choice, and Canonical ships a small
`lowlatency-kernel` package whose entire contents is one GRUB snippet adding
`preempt=full rcu_nocbs=all`.

Both supported releases end up in exactly the same place:

| Release | Package | Resolves to |
|---|---|---|
| 24.04 | `linux-lowlatency-hwe-24.04` | `linux-image-generic-hwe-24.04` + `lowlatency-kernel` |
| 26.04 | `linux-lowlatency` | `linux-image-generic` + `lowlatency-kernel` |

Same kernel (7.0), same preemption model, plus VSTOS's own `threadirqs` and
`usbcore.autosuspend=-1`.

The old `CONFIG_PREEMPT` flavour still exists, but **only on 24.04 and only at
kernel 6.8** (`sudo apt install linux-lowlatency` there). On 26.04 it is gone from
the archive entirely. That trade — a purpose-built image against two years of
kernel work — is argued in [docs/DESIGN.md](docs/DESIGN.md).

---

## Latency, honestly

Three numbers get confused with each other, so they are worth separating.

| | |
|---|---|
| **FBKSuppressor's own latency** | **0 samples.** Not "low" — zero, by construction, verified by its own test suite at 44.1 and 48 kHz. |
| **The plugin host's latency** | 0 samples. Carla adds no buffering when plugins are run in-process, which is how VSTOS configures it. |
| **The trip out of the console and back** | **8.0 ms** at the default 128×3 @ 48 kHz — 4 ms each way. |

That last number is the one you can hear, and it is not the plugin's: it is the
cost of leaving the WING over USB and coming back. It is the same cost any
outboard insert on a digital console pays. If it matters for what you are doing —
in-ear monitors, say — lower `PERIOD` to 64 for 4 ms total and verify with
`vstos-status xruns` over a full rehearsal before trusting it to a service.

USB interrupt timing, not the CPU, is what sets the floor here. A faster machine
does not buy a smaller buffer.

---

## Getting started

```sh
vstos-status              # is anything wrong, and what
vstos-status xruns        # the number that decides whether the buffer is small enough
vstos-apply               # re-read /etc/vstos/vstos.conf and restart the session
```

Everything the machine does is described by one file, `/etc/vstos/vstos.conf`:
which interface, what sample rate, how big a buffer, which channel the insert is
on, whether there is a screen.

---

## Releases

| Branch | Publishes | Tag |
|---|---|---|
| `dev` | **pre-release** | `v0.1.0-dev.<run number>` |
| `main` | **release** | `v0.1.0` |

Every push to either branch lints, runs the suite, provisions a clean Ubuntu
24.04 container end to end, builds the bundle, installs from that bundle, and
only then publishes — in the same run, so a release carries the exact artefact
that was tested.

**The version lives in `VERSION`** and is the single source of truth. Pre-release
tags append the run number, so `dev` never needs a bump. A release does: if
`v<version>` already exists, the publish step fails with a message rather than
replacing an artefact someone may already have installed from. So a real release
is: bump `VERSION`, merge to `dev`, check the pre-release, merge to `main`.

### What a release contains

A **bundle** — `vstos-<version>.tar.gz`, about 50 kB — not an ISO:

```sh
tar xzf vstos-*.tar.gz && cd vstos-*/
sudo ./provision/vstos-provision
sudo reboot
```

The ISO is absent for a concrete reason: a GitHub release asset is capped at 2 GB
and an Ubuntu-based installer image is past that, so it cannot be attached to one.
The bundle is the same code the ISO runs and contains `build/build-iso.sh`, which
rebuilds the image in a single command — a better deal than a 3 GB download. CI's
ISO workflow keeps a built image as a workflow artifact and attaches its checksum
to the release, so a locally built one can be checked against it.

---

## Documentation

| | |
|---|---|
| [docs/LIVE-USB.md](docs/LIVE-USB.md) | Running from a USB stick: building it, persistence, and why it cannot touch your disks |
| [docs/DESIGN.md](docs/DESIGN.md) | Why JACK and not PipeWire, why X11 and not Wayland, and what was rejected |
| [docs/WING.md](docs/WING.md) | Console setup, USB routing, sample rate, and what to check when there is no sound |
| [docs/PLUGINS.md](docs/PLUGINS.md) | What is installed, what to reach for, and how to add more |
| [docs/OPERATING.md](docs/OPERATING.md) | Running it: remote control, saving racks, recovery, updates |

---

## Repository layout

```
provision/          the provisioner - the single source of truth for the system
  vstos.conf.default    every tunable, with the reasoning
  packages/*.list       what gets installed and why each entry is there
  steps/                ten ordered, idempotent steps
system/             files installed onto the target
  bin/                  vstos-jack, vstos-session, vstos-status, the shared library
  systemd/              the three units
  carla/                host settings and the boot rack
build/              the ISO builder and its autoinstall answers
tests/              34 checks; ./tests/run-tests.sh
```

---

## Status

Everything here has been exercised on **both** Ubuntu 24.04 and 26.04: the
provisioner runs clean from a bare root to a verified system on each, the curated
package set resolves and installs, and Carla loads the shipped boot rack and
instantiates FBKSuppressor with all 21 of its parameters. 42 tests pass on both,
and CI provisions both on every push.

What has **not** been tested is a physical WING, because this was built without
one in reach. The device handling is written against the WING's documented
behaviour — 48×48 channels, USB Audio Class 2, class-compliant on Linux with no
driver — and the resolver matches the console by the product string it reports
rather than by a vendor and product ID this project cannot verify first-hand.
`vstos-status cards` prints exactly what the machine sees, which is the first
thing to run when the console is plugged in for real. See
[docs/WING.md](docs/WING.md).

---

## Licence

The VSTOS scripts and configuration are MIT (see [LICENSE](LICENSE)).

They install software that is not: Carla is GPL-2.0+, the plugin library is GPL,
LGPL and MIT, and Ubuntu is Ubuntu. VSTOS installs those from the Ubuntu archive
rather than redistributing them, so their licences reach you unchanged from their
authors. FBKSuppressor is installed from its own releases and carries its own
terms.

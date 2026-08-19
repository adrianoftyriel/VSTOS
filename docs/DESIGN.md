# Design

Why VSTOS is put together the way it is, and what was rejected on the way.

---

## The shape of the thing

An appliance, not a workstation with the desktop hidden. The distinction shows up
in every decision below: an appliance is allowed to be less capable in exchange
for being more predictable, and the failure mode that matters is not "a feature is
missing" but "it did something unexpected during a service".

Three processes, in order:

```
vstos-jack.service     jackd on the console's USB interface
      ↓
vstos-a2jmidi.service  the console's USB MIDI, bridged into JACK
      ↓
vstos-session.service  Carla, on a screen if there is one
```

That is the whole system. Everything else is configuration.

---

## Ubuntu 24.04 LTS, and the low-latency kernel

Ubuntu changed how the low-latency kernel is delivered between 24.04 and 26.04:

- **24.04** ships `linux-lowlatency` as a separate kernel flavour — a 1000 Hz
  tick, full preemption, threaded interrupt handlers.
- **26.04** retires it. The generic kernel gained boot-time responsiveness tuning,
  and the flavour is replaced by `linux-generic` plus a small user-space
  `lowlatency-kernel` package whose job is to set the GRUB command line.

VSTOS is built on **24.04 LTS**, and the reason is not conservatism. The
hardware-enablement track `linux-lowlatency-hwe-24.04` currently carries **kernel
7.0** — the same kernel 26.04 ships — as a genuine low-latency *flavour*. So the
LTS base gives both the current kernel and the real thing rather than a tuned
generic one.

`provision/steps/20-kernel.sh` knows about both arrangements and picks by release,
so moving the base forward does not silently turn this into a machine running a
desktop kernel.

### Boot parameters

| | |
|---|---|
| `threadirqs` | Interrupt handlers run in schedulable threads, so the USB controller's handler can be prioritised *against* audio processing rather than preempting it blindly. |
| `usbcore.autosuspend=-1` | Never power-manage a USB device. A console that autosuspends between soundchecks comes back as a new card index, and the rig is pointing at nothing. |

**`mitigations=off` is deliberately not set.** It buys real CPU headroom and is
widely recommended for audio machines, and what it buys it with is the CPU
vulnerability mitigations. On a box that sits on a venue's network that is a
judgement for the operator, not a default. To enable it, add it to
`/etc/default/grub.d/99-vstos.cfg` and run `update-grub`.

---

## JACK, not PipeWire

PipeWire is the right default for a laptop and the wrong one here.

The case for PipeWire is that it handles devices appearing and disappearing
gracefully, and that it is what Ubuntu ships. The case against, for this machine,
is that it is a graph engine with its own scheduling sitting between the host and
the card, on a box where the card is bolted to the console and never changes.
JACK2 talks to ALSA directly, its period and buffer count are exactly what you
configured rather than a negotiated quantum, and it is Carla's own preferred
driver on Linux.

The property being bought is **determinism**. On an appliance, "the buffer is
whatever the graph settled on" is not a feature.

What that costs: no automatic handling of a second sound device, and no desktop
audio. Neither is something this machine does.

---

## Carla, as the host

The requirement is a host that loads VST3 (FBKSuppressor is VST3), runs with no
desktop, exposes a patchbay across 48 channels, and can be driven from somewhere
else when the box has no screen. Carla is the only thing in the Ubuntu archive
that does all four.

Two details that turned out to matter, both verified rather than assumed:

- **`carla -n` builds a `QCoreApplication`, not a `QApplication`.** Headless Carla
  therefore needs no X server, no `DISPLAY`, and no offscreen platform plugin. It
  was worth checking, because the alternative design — running a virtual X server
  just to host plugins — is a great deal more machinery.
- **Carla's VST3 loader discovers FBKSuppressor with no display attached.** Carla
  2.5.8 bundles JUCE 7.0.1 internally; FBKSuppressor is built against JUCE 8. That
  combination works, and it is the kind of thing that is cheaper to test than to
  reason about.

Carla runs plugins **in-process** (`PreferPluginBridges=false`). Bridging would
isolate a plugin crash into a separate process, at the cost of an extra buffer of
latency per plugin. For a live insert that is the wrong side of the trade.

Process mode is **multiple clients**: each plugin becomes its own JACK client with
its own ports, which is what makes an instance on channel 7 patchable to console
channel 7 rather than to a slot in a fixed rack.

---

## X11, not Wayland — and no desktop either

Almost every Linux audio plugin editor is an X11 window that expects to be
embedded in its host: every LV2 X11 UI, every JUCE VST3, FBKSuppressor included.
Under a Wayland compositor they reach the screen only through XWayland, and
embedding is precisely the part that works least well.

A compositor would buy nothing here anyway. There is one application and it is
fullscreen.

So: an X server with no display manager, no desktop environment, and **one**
client. Openbox is present for exactly one reason — plugin editors are separate
top-level windows and something has to let you raise, move and close them. Without
a window manager the first plugin you open lands at 0,0 underneath the host with
no way to move it. Its configuration turns off everything that would make it feel
like a desktop: one workspace, no root menu, no keyboard shortcuts that could
strand an operator in an empty session.

Openbox is started with `--config-file /usr/share/vstos/openbox-rc.xml` rather
than by writing `/etc/xdg/openbox/rc.xml`. That path is a dpkg conffile; writing
it makes every later `openbox` upgrade stop at an interactive "keep yours or the
maintainer's?" prompt, which under apt's noninteractive frontend is not a prompt
but a failed dpkg run and a machine with packages half-configured. **VSTOS does
not write files dpkg owns.**

### `UI_MODE=auto` degrades rather than fails

`auto` starts the on-screen host if a DRM connector reports `connected`, and runs
headless otherwise. The test is for a *connected* connector, not for
`/dev/dri/card0` — that node exists on any machine with a GPU, monitor or not, so
testing for it would choose kiosk on every rack-mounted box and then fail to find
a screen.

If the X server fails anyway, the session falls back to headless. A console that
passes audio with a blank screen is a working console; one that refuses to start
the host because a monitor is faulty is not.

---

## Realtime configuration

```
@audio  -  rtprio     95      # the ceiling
@audio  -  memlock    unlimited
@audio  -  nice       -19
```

`JACK_RT_PRIORITY` (80 by default) is the actual priority, and the gap to 95 is
deliberate: threaded interrupt handlers must be able to preempt audio processing
in order to deliver the USB packets that audio processing is waiting for. Setting
the engine to 95 inverts that and makes latency worse.

`kernel.sched_rt_runtime_us = 990000` gives the engine 99% of each period and
keeps 1% for everything else. The obvious move is `-1`, which disables realtime
throttling entirely; it is not done, because with it off a plugin that spins in
its process callback takes the machine with it and the only way back is the power
switch. On a box at the back of a venue that is the difference between a bad sound
and a dead PA.

---

## Finding the console

The resolver matches the console by **product string**, case-insensitively,
against the ALSA card id, the card's long name, and the USB product string — not
by a USB vendor and product ID.

That is a considered choice. A `VID:PID` pair is more precise when it is right,
and this project has no WING to read one off. A wrong ID fails closed and
silently: the console is plugged in, the light is on, and nothing appears. A
product string is printed by the device itself, matches every WING variant
(WING, WING Rack, WING Compact) because they all present the same interface, and
is checkable in one command — `vstos-status cards` prints exactly what the machine
sees.

`AUDIO_DEVICE` pins a card explicitly when matching is not what you want.
`AUDIO_DEVICE_FALLBACK` is **off** by default: on an appliance, coming up on the
wrong interface is worse than not coming up, because it looks like it worked.

---

## Provisioning

One code path, used by both the ISO and by hand. Ten ordered steps under
`provision/steps/`, each idempotent, each able to run inside the installer's
chroot where there is no init to talk to.

The properties that matter:

- **It never overwrites `/etc/vstos/vstos.conf`.** Re-provisioning a machine that
  has been tuned for its own USB timing must not silently reset `PERIOD`.
- **It never overwrites a saved rack.** That is the most valuable file on the box.
- **It keeps a copy of itself** at `/usr/share/vstos/src`, which is what lets
  `vstos-apply` re-render everything after a configuration change on a machine
  that may have no network where it stands.
- **A failed FBKSuppressor download is a warning, not a failure.** Everything else
  about the machine is still correct, and the missing piece is one command to fix.

---

## What was rejected

**A custom live ISO built with debootstrap.** Full control, and a large amount of
fragile machinery — squashfs, GRUB for both BIOS and UEFI, a boot arrangement to
keep in step with whatever Canonical changes next — in exchange for very little.
Repacking the official image with an autoinstall answer file keeps Canonical's
signed base and their boot arrangement, and `xorriso -boot_image any replay`
copies that arrangement rather than reconstructing it.

**A read-only root with an overlay.** Genuinely attractive for a box that gets
switched off at the wall. Not done yet because it complicates saving a rack, which
is the thing operators will do most. Noted as future work rather than dismissed.

**One FBKSuppressor per channel in the boot rack.** Each costs about 3% of a core,
so all 48 would fit on a modern CPU. A rack you did not ask for is a rack you have
to reason about at soundcheck.

**PipeWire, `mitigations=off`, and a `VID:PID` device match** — each argued above.

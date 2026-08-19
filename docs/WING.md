# The WING

Setting up the console, and what to check when there is no sound.

---

## What the connection is

The WING carries a **48-in / 48-out, 24-bit USB audio interface** on its USB type-B
port. On Linux it is class-compliant — USB Audio Class 2 — so `snd-usb-audio`
claims it and no driver is installed, downloaded or configured. That is true of
every variant in the family; WING, WING Rack and WING Compact all present the same
interface, which is why VSTOS matches on the product string rather than on a model.

VSTOS treats those 48 channels as **insert sends and returns**. It does not mix,
it does not route, and it has no opinion about your show file. The console sends a
channel out over USB, VSTOS processes it, the console takes it back.

---

## On the console

Two settings, both under **Setup → Global → Audio**:

1. **Sample rate.** 44.1 or 48 kHz. Whatever you pick here must match
   `SAMPLE_RATE` in `/etc/vstos/vstos.conf`, or JACK will refuse to start rather
   than run at the wrong rate. 48 kHz is VSTOS's default. Both are native rates for
   FBKSuppressor, so neither costs you anything.

2. **Clock source.** Leave the console as clock master. It is the device with the
   converters on it; the computer should follow.

Then set up the insert itself. On the channel you want processed, set the insert
send to **USB out N** and the insert return to **USB in N**, where N is
`INSERT_CHANNEL` in `/etc/vstos/vstos.conf` — 1 by default.

That is the whole console-side configuration.

---

## Choosing a channel

`INSERT_CHANNEL` picks which USB pair the shipped rack uses:

```sh
sudo nano /etc/vstos/vstos.conf     # INSERT_CHANNEL=7
sudo vstos-apply
```

`vstos-apply` re-renders the rack and restarts the session. It refuses to do
anything if the configuration does not parse, so a typo costs you a message rather
than a silent rig.

To process more than one channel, add instances in the host and save — see
[OPERATING.md](OPERATING.md).

---

## Buffer size

The default is `PERIOD=128`, `NPERIODS=3`: **8.0 ms** out of the console and back.

USB audio interrupt timing is what sets the floor, not the CPU, so a faster
machine does not buy a smaller buffer. 128 is the smallest period reported to run
a 48-channel USB console without dropouts.

```
 64 × 3 @ 48k =  4.0 ms    worth trying; verify before trusting it to a service
128 × 3 @ 48k =  8.0 ms    the default
256 × 3 @ 48k = 16.0 ms    the safe retreat
```

The way to decide is not to guess:

```sh
vstos-status xruns
```

An xrun is a period the engine missed — an audible click. One at load time is
noise. A recurring count during a rehearsal means `PERIOD` is too low **for this
machine**, and the fix is to double it and re-run `vstos-apply`.

Run a full rehearsal at the buffer you intend to use before a service. A rig that
is clean for ten minutes and drops out during the third hymn was never clean.

---

## MIDI

With `MIDI_BRIDGE=1` (the default), the console's USB MIDI ports are bridged into
JACK MIDI by `a2jmidid`, which puts footswitches, encoders and scene changes where
plugins can be told to listen to them. They appear in the patchbay alongside the
audio ports.

Turn it off with `MIDI_BRIDGE=0` if you are not using it; it is one fewer process.

---

## When there is no sound

Work down this list. The first command answers most of it.

```sh
vstos-status
```

**"no sound cards at all"** — the console is not enumerating. Check the USB cable
and that the console is powered up. `lsusb` lists what the machine can see at all.
USB enumeration of a 48×48 interface is not instant, and VSTOS waits 45 seconds
for it at boot, so a console switched on at the same moment as the host is fine.

**"nothing matches 'WING'"** — the machine sees a card but not one whose name
contains WING. `vstos-status cards` prints every card with its id and long name;
if the console is in that list under a name you did not expect, either set
`AUDIO_DEVICE_MATCH` to something that matches it, or pin it outright:

```sh
AUDIO_DEVICE="hw:2"      # in /etc/vstos/vstos.conf, then vstos-apply
```

**"JACK is not running"** — the engine failed to start. The reason will be in its
log:

```sh
journalctl -u vstos-jack -n 50
```

The most common cause is a sample rate mismatch: the console is at 44.1 and
`SAMPLE_RATE` says 48000, or the reverse. JACK says so explicitly. Fix whichever
end is wrong.

**"the running rate is not the configured one"** — the console's global rate wins,
because it is the clock master. Change the console, or change `SAMPLE_RATE` to
agree with it.

**Everything is running and there is still no audio** — then the signal is not
reaching the plugin, which is a routing question rather than a system one:

```sh
vstos-status ports
```

That prints the JACK graph with its connections. You are looking for
`system:capture_N → FBKSuppressor:input_1` and `FBKSuppressor:output →
system:playback_N`, with N matching the insert you set up on the console. If those
connections are there and the console still hears nothing, the insert on the
console is not on the channel you think it is.

---

## Things known about this that are worth knowing

**Reports of occasional xruns.** Linux users of the WING have reported xruns that
raising the buffer size reduces but does not always eliminate entirely. If you see
that, `PERIOD=256` is the retreat, and it costs 16 ms rather than 8.

**Hard lock-ups on power-off have been reported.** Switching the console off while
the host is running has been reported to hang the machine on some kernels. Nothing
VSTOS does can prevent that; stopping the session first is the safe order if you
are switching things off separately:

```sh
sudo systemctl stop vstos-session vstos-jack
```

**This has not been tested against a physical WING.** VSTOS was built without one
in reach. The device handling follows the WING's documented behaviour and is
written to fail loudly and describably rather than to guess — which is why
`vstos-status cards` exists and why `AUDIO_DEVICE_FALLBACK` is off by default. The
first thing to do with a real console is run it.

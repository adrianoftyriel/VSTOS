# Operating VSTOS

Day-to-day: driving it, changing it, and getting it back when it goes wrong.

---

## The three commands

```sh
vstos-status              # is anything wrong, and what
vstos-apply               # re-read /etc/vstos/vstos.conf and restart the session
vstos-install-fbksuppressor   # install or update FBKSuppressor
```

`vstos-status` takes a topic if you want less of it: `cards`, `engine`, `xruns`,
`ports`, `plugins`, `session`.

---

## Configuration

One file: `/etc/vstos/vstos.conf`. Every unit and script reads it and nothing
else, so the machine is described entirely by what is in there. Each setting is
commented in place with the reasoning.

```sh
sudo nano /etc/vstos/vstos.conf
sudo vstos-apply
```

`vstos-apply` validates before it changes anything. An invalid value costs you a
message; it does not cost you a rig that will not start.

The settings you are most likely to touch:

| | |
|---|---|
| `INSERT_CHANNEL` | which USB channel the shipped rack processes |
| `PERIOD` | buffer size — the latency/reliability trade |
| `SAMPLE_RATE` | must match the console |
| `UI_MODE` | `auto`, `kiosk` or `headless` |

Provisioning never overwrites this file, so re-running it on a machine you have
tuned is safe.

---

## Driving it from somewhere else

The box may have no screen. Carla's OSC control surface is how you drive it
anyway, from a laptop or tablet running `carla-control`:

```sh
carla-control osc.tcp://vstos.local:22752/Carla
```

`vstos-status session` prints the exact address for the machine in front of you.
Avahi is installed, so `vstos.local` works without knowing the IP — which matters
on a venue's network you do not control.

Anything you can do in the host you can do there: add plugins, change parameters,
open editors, save.

There is no authentication on that port. It is protected by being on your network
and nothing else, which is the same protection your console's remote-control port
has. Do not put either on a network you do not trust.

For anything else, SSH in as the admin account created at install time:

```sh
ssh vstos@vstos.local
```

---

## Racks

The rack that loads at boot is `/var/lib/vstos/projects/default.carxp`.

### Adding a second processed channel

In the host: add another FBKSuppressor, then patch `system:capture_N` to its
input and its output to `system:playback_N`. Then **File → Save**, over
`default.carxp`. That is it — the saved file is what boots next time.

From a shell, if you would rather:

```sh
jack_connect system:capture_7 FBKSuppressor-2:input_1
jack_connect FBKSuppressor-2:output system:playback_7
```

then save in the host so it survives a restart.

### Keeping more than one rack

```sh
sudo -u audio-op cp /var/lib/vstos/projects/default.carxp \
                    /var/lib/vstos/projects/sunday-morning.carxp
```

Point `CARLA_PROJECT` at whichever one should boot, then `vstos-apply`.

Provisioning never overwrites a saved rack. It is the most valuable file on the
machine — back it up somewhere that is not the machine.

```sh
scp vstos@vstos.local:/var/lib/vstos/projects/*.carxp ./
```

---

## Before a service

```sh
vstos-status
```

Everything green, then a rehearsal at the buffer size you intend to use. Then:

```sh
vstos-status xruns
```

Zero is what you want. A count here means `PERIOD` is too low for this machine —
double it, `vstos-apply`, and rehearse again. A rig that is clean for ten minutes
and drops out during the third hymn was never clean.

---

## When it goes wrong

**No audio at all** — start with `vstos-status`; [WING.md](WING.md) walks the
whole list.

**The host has disappeared from the screen** — it is restarting; the unit is set
to come back always. `systemctl status vstos-session` says why. Audio keeps
passing while the host restarts only if the engine stayed up, which it usually
does — the two are separate units on purpose.

**A plugin took the host down with it** — plugins run in-process, so a crash in
one restarts the host. If a particular plugin does it repeatedly, take it out of
the rack and save. `journalctl -u vstos-session -n 100` names it.

**The machine will not boot to a working session** — a console with a keyboard
gets you a login on tty1 regardless; the session runs on tty7 and cannot lock you
out. From there:

```sh
sudo systemctl stop vstos-session
journalctl -u vstos-jack -u vstos-session -b
```

**A configuration change broke it** — the shipped defaults are kept:

```sh
sudo cp /usr/share/vstos/vstos.conf.default /etc/vstos/vstos.conf
sudo vstos-apply
```

**Everything is confusing** — re-provision. It is idempotent, it keeps your config
and your racks, and it puts every generated file back:

```sh
sudo /usr/share/vstos/src/provision/vstos-provision
```

---

## Updating

**FBKSuppressor:**

```sh
sudo vstos-install-fbksuppressor            # newest release
sudo vstos-install-fbksuppressor v0.1.0     # or a specific tag
sudo systemctl restart vstos-session
```

It verifies the download against the release's published checksums, and does
nothing at all if the version asked for is already installed.

**Plugins and the system:**

```sh
sudo apt update && sudo apt upgrade
```

Note that the automatic upgrade timers are deliberately **disabled** on VSTOS.
Updating is a decision to take between services, not during one — an unattended
upgrade waking up mid-service costs CPU and disk at the worst possible moment.
That means keeping the machine current is your job; put it in the calendar.

**VSTOS itself:**

```sh
cd /usr/share/vstos/src && sudo git pull && sudo ./provision/vstos-provision
```

---

## What runs, and in what order

```
vstos-jack.service      the engine. Waits up to 45s for the console, restarts
                        forever, so a console powered on later still comes up.
vstos-a2jmidi.service   the console's USB MIDI, bridged into JACK.
vstos-session.service   the host. Waits for the engine, then starts on a screen
                        if there is one and headless if not.
```

```sh
systemctl status vstos-jack vstos-a2jmidi vstos-session
journalctl -u vstos-jack -f
```

The journal is persistent and bounded to 512 MB with a month's retention, so "it
dropped out during the second reading" is still answerable a week later.

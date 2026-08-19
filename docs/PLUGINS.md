# The plugin library

**543 LV2 plugins in 122 bundles, plus 22 VST3 bundles.** All free software from
the Ubuntu archive, so they update with the rest of the machine and are
redistributable inside an ISO.

Chosen for live sound on a digital console rather than for studio production. The
question asked of each entry was "would a system tech reach for this during a
service", which is why there are no synthesisers, samplers or drum machines here.

---

## What is installed

### Linux Studio Plugins — 176 plugins

The centrepiece, and the reason the library is worth having at all. Parametric EQ
up to 32 bands, compressor, sidechain compressor, expander, gate, limiter,
de-esser, dynamic processor, crossover, delay compensator, impulse-response
loader, loudness and spectrum analysis — mono, stereo and left/right variants of
most of it.

Consistently the highest-rated free suite on Linux, and unusual in shipping **VST3
as well as LV2**, so the same plugin loads whichever format you reach for.

### Calf Studio Gear — 51 plugins

Compressor, multiband compressor, sidechain gate, EQ in 5, 8, 12 and 30-band
forms, reverb, exciter, bass enhancer, vintage delay, analyser. Very legible
interfaces, which matters when someone other than you has to drive the rig.

### x42 — 113 plugins

Robin Gareus's set. `fil4` EQ, a true-peak digital limiter, `a-comp`, `a-exp`,
`a-delay`, and the meter collection that makes a streamed or broadcast service
straightforward: EBU R128 loudness, K-meters, true-peak, phase correlation,
goniometer, spectrogram. Also `tuna`, a tuner accurate enough for a line check.

### guitarix — 72 plugins

Amp and cabinet models plus a large effects set. This is what turns a DI'd guitar
into something that sits in a mix without a physical amp on stage.

### ZamAudio — 17 plugins, LV2 and VST3

ZamComp, ZamCompX2, ZamEQ2, ZamGate, ZamGateX2, ZaMaximX2, ZaMultiComp,
ZamGEQ31, ZamTube, ZamDelay, ZamDynamicEQ. Small, fast, and the 31-band graphic
is the familiar shape for ringing out a room by hand when you want to do it the
old way.

### MDA — 36 plugins

The classic free set, ported to LV2. Worth having for the utilities alone.

### Invada — 18 plugins

Compressor, delay, filters, tube distortion, meters.

### eq10q — 17 plugins

Parametric EQ, compressor, gate, bass enhancer.

### DragonFly Reverb — 4 plugins, LV2 and VST3

Hall, room, plate and early reflections. The best free reverb on the platform by
common consent, and the one to reach for first.

### abGate

A clean, low-CPU noise gate.

### fomp

Fons Adriaensen's plugins as LV2 — parametric EQ, phaser, chorus.

### LADSPA: swh (96), TAP (19), CAPS

The older generation, still useful and close to free CPU-wise. TAP Reverberator
and TAP Dynamics in particular have outlived most of what replaced them.

### FBKSuppressor — VST3

Zero-latency feedback, room-noise and mains-hum suppression, working
subtractively rather than by notching. Loaded in the boot rack; see the main
[README](../README.md).

---

## What to reach for

| For | Try |
|---|---|
| Feedback on a live mic | **FBKSuppressor** first. It cancels the tone rather than notching the band, so the voice at that frequency survives. |
| Ringing out a room the old way | ZamGEQ31, or LSP Parametric EQ x32 if you want to be surgical |
| Channel strip on a vocal | LSP Compressor → LSP Parametric EQ x16 → LSP De-esser |
| Bus compression | LSP Sidechain Compressor, or Calf Multiband Compressor |
| Protecting the PA | x42 dpl (true-peak limiter) — last in the chain, always |
| Reverb | DragonFly Hall or Plate |
| Gating a drum kit | LSP Gate, or abGate for something simpler |
| A DI'd guitar with no amp | guitarix amp models |
| Metering for a stream | x42 EBU R128 meter |
| Checking a room's response | LSP Spectrum Analyzer |
| Tuning up | x42 tuna |

---

## Adding more

Anything in the Ubuntu archive:

```sh
sudo apt install <package>
```

Carla finds LV2 in `/usr/lib/lv2` and `~/.lv2`, and VST3 in `/usr/lib/vst3` and
`~/.vst3`, which is where the archive and `vstos-install-fbksuppressor` put them.
Nothing needs configuring; refresh the plugin list in the host and it is there.

A plugin you built or downloaded yourself:

```sh
sudo cp -r MyPlugin.vst3 /usr/lib/vst3/
sudo cp -r MyPlugin.lv2  /usr/lib/lv2/
```

### Also worth having

**zita-rev1 and zita-at1** — Fons Adriaensen's reverb and autotuner. They are
deliberately not in the default set because they are *standalone JACK
applications*, not plugins: the host cannot instantiate them. They are still
excellent, and on this machine they are genuinely usable, because they appear in
the JACK patchbay alongside everything else and can be patched into the signal
path.

```sh
sudo apt install zita-rev1 zita-at1
zita-rev1 &                          # then patch it in the host's patchbay
```

zita-rev1 is the reverb to use when DragonFly is too coloured.

---

## Why some well-regarded plugins are missing

The library is restricted to free software in the Ubuntu archive, and that
constraint costs a few names worth knowing about:

- **Surge XT**, **Vital/Vitalium**, **sfizz** — not packaged for 24.04. All are
  instruments, so none of them is what this machine is for.
- **Airwindows**, **ChowDSP** — open source and very well regarded, but not
  packaged. Install them by hand into `/usr/lib/vst3` if you want them.
- **TAL**, **Valhalla Supermassive**, and other freeware VST3s — free of charge,
  but not free software, and their redistribution terms are not clear enough to
  put inside an ISO. Nothing stops you installing them on your own machine.
- **noise-repellent** — an LV2 noise reducer, not packaged for 24.04. On this
  machine FBKSuppressor covers the same ground at zero latency.

The rule VSTOS applies is: it installs from the archive rather than
redistributing, so every licence reaches you unchanged from its author. Anything
that would need bundling under unclear terms is left for you to decide about.

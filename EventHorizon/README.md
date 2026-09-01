# Event Horizon

![A black hole crossing a desktop, lensing the windows around it](../docs/over-desktop.png)

A menu bar break timer. When the timer runs out a black hole crosses your screen,
lensing your actual windows around itself and eating them as it passes. It leaves
you sitting in front of empty space for the length of your break, then crosses
back and hands your desktop over.

The lensing is real: photon paths are integrated as Schwarzschild geodesics, and
the desktop is treated as a flat plane behind the hole. Undeflected rays map to
the identity and the pipeline is raw display-encoded end to end, so untouched
pixels are reproduced exactly and only the bent region is ours.

## Build and run

```sh
./build.sh
open "/Applications/Event Horizon.app"
```

Builds a universal (arm64 + x86_64) app bundle and installs it to
`/Applications`, so it shows up in Finder, Spotlight and Login Items like any
other app. The icon is rendered by `tools/makeicon.swift` using the same shader
the app runs, so it is an actual render of the black hole rather than a drawing
of one; regenerate it with:

```sh
cd tools && cp makeicon.swift main.swift && swiftc -O -o makeicon main.swift ../Shaders.swift
./makeicon AppIcon.iconset && iconutil -c icns AppIcon.iconset -o ../AppIcon.icns
```

### Screen Recording permission

This is the one thing that will bite you. The app reads the screen it is about to
swallow, so it needs **Screen Recording**. macOS prompts on first launch, and you
must **quit and relaunch** afterwards for it to take effect.

Without it, capture fails, there is no desktop to eat, and the overlay falls back
to an opaque starfield — which looks exactly like a black lock screen rather than
an effect over your windows. The overlay now says so on screen, the menu bar shows
a warning item, and `~/Library/Logs/EventHorizon.log` records
`screenCaptureGranted=`.

Grant it once and it sticks, because the app is signed with a stable
self-signed certificate. Create that certificate once with:

```sh
tools/make-signing-cert.sh
```

It generates a code signing certificate in your login keychain and marks it
trusted for code signing (macOS will ask you to authorise the trust change).
`build.sh` then signs with it, which pins the app's designated requirement to the
certificate rather than to the binary's hash:

```
designated => identifier "local.eventhorizon.app" and certificate leaf = H"04b4625046..."
```

That string is identical across rebuilds, so macOS keeps honouring the grant.
Without the certificate `build.sh` falls back to ad-hoc signing, where the
requirement is a bare `cdhash` that changes on every build and silently voids the
permission — in that case the script runs `tccutil reset ScreenCapture
local.eventhorizon.app` on install so you at least get a fresh prompt instead of
a silent failure.

Nothing is recorded or written anywhere. The capture stream runs only for the
duration of a break and is torn down the moment it ends.

### If the break is just a black screen

That is the no-permission fallback, not an overlay bug. Check the log:

```sh
tail ~/Library/Logs/EventHorizon.log
```

`screenCaptureGranted=false` or `capture FAILED` confirms it. Note that running
the binary directly from a shell reports `true` misleadingly — TCC attributes a
shell-launched process to its parent terminal, so always test via `open`.

## Using it

Everything is in the menu bar item, which shows a countdown in the last five
minutes before a break.

- **Take a break now** / **Reset the timer** / **Pause**
- **Interval** — presets from 20/5 to 90/15, plus **Custom…** for any pair of
  values. Default is 50 minutes of work, 10 minute break.
- **Direction** — which way the hole crosses. Default is right to left.
- **Speed** — 0.25x, 0.5x, 1x, 1.5x. Scales the crossings *and* the disk's own
  rotation, so the whole thing slows together rather than the hole sliding
  through a normal-speed disk.
- **Loop the crossing** — on by default: the hole keeps crossing for the whole
  break. Turn it off and it crosses once, then parks mid-screen until the break
  ends.
- **Clear the whole screen** — off by default. On, the hole's wake stays consumed
  so the display is emptied as it crosses.

During a break the overlay takes keyboard and mouse. **Moving the pointer ends
the break** — about 45 points of travel, ignored for the first 1.5 seconds so a
hand already resting on the mouse does not skip it instantly. A click does the
same. Holding Esc for a second and **End break now** in the menu bar both still
work.

Note this makes the break easy to dismiss by accident: any deliberate mouse
movement ends it. Raise `mouseToDismiss` in `BreakController` for a firmer
interruption, or set it very high to fall back to Esc only.

Sitting idle for longer than a break length silently resets the timer, so you
don't get ambushed the moment you sit back down.

If it ever wedges, `pkill -f EventHorizon` removes it.

## How the effect is shaped

**It is a real object, not a sprite.** The camera's forward axis is fixed at the
screen centre and the hole is positioned by moving the camera sideways, not by
shifting the image. It therefore turns as it crosses — the disk foreshortens, the
lensing goes asymmetric, and the Doppler-bright side swaps. Rendering the same
instant with the hole at three screen positions gives images that differ by 17-24
levels out of 255; translating a sprite would give exactly zero.

![The same moment with the hole at three screen positions](../docs/parallax.png)

Two more things keep it from being a screen-wide mush:

**The warp is local.** Gravitational lensing falls off as 1/b, which would visibly
displace the entire screen — at a realistic hole size the far corners still shift
by tens of pixels. `warpPoints` (420 pt) applies a smooth `exp(-2.6·t³)` rolloff
to the displacement so it decays to nothing about 500 pt out. Everything beyond
that stays fully transparent and live. This is the same idea as the "warp reach"
control in [s0xDk/blackhole_screensaver_macos](https://github.com/s0xDk/blackhole_screensaver_macos).

**The disk has thickness.** It is integrated as a slab along the ray rather than
sampled at a single plane crossing, and its turbulence mixes a Keplerian-sheared
layer with a solid-body one. Shear alone winds noise into concentric rings, which
is what made an earlier version read as flat painted circles.

**The gas is filamentary and visibly moving.** `diskTurb` samples anisotropically
— the angular term rides a fixed-radius circle while radius gets a much higher
frequency — so features stretch along the orbit into strands rather than blobs. A
ridged transform (`1 - |2n-1|`) turns those into thin bright lanes. Three things
matter for how alive it looks, and they fight each other:

- `omega` (7.0·r^-1.5) sets the flow speed. It was 3.0 while fixing the ring
  problem, which made the disk look static.
- The slab half-thickness (`0.06 + 0.032·r`) sets sharpness. A thick slab
  averages its own detail away along the ray.
- `diskGain` sets exposure. Too high and every strand clips to white, which
  destroys exactly the structure the other two produce.

Measured on a 1400x820 render: mean |delta| of 7.4/255 between frames 0.4 s
apart over the lit disk (was 1.1 before this pass), with 0.01% of pixels blown
out.

### One design choice worth knowing

What the hole has already crossed *stays* consumed, so the desktop empties
progressively and the screen is fully dark by the time the break proper starts.
The distortion itself is always local to the hole — it is the consumption that
accumulates. If you would rather it restore the desktop in its wake and leave the
screen usable, set `eating: false` on the `.swallow` case in `BreakController`.

## Shape of the code

- `Shaders.swift` — the Metal source, as a string. Compiled at load time because
  the offline `metal` compiler ships only with full Xcode, and only the Command
  Line Tools are installed here.
- `ScreenCapture.swift` — one `SCStream` per display. The content filter excludes
  our own application; without that the overlay would capture its own output and
  become an infinite mirror.
- `OverlayView.swift` — `CAMetalLayer` view, premultiplied alpha over the live
  screen, uniforms.
- `BreakController.swift` — one borderless window per display, the
  swallow/hold/release arc, `sweep()`, the Esc escape hatch.
- `AppDelegate.swift` — status item, menu, work timer, idle detection.

## Tuning

The arc lives in `BreakController.tick()`. `baseSwallowDur` (14s) and
`baseReleaseDur` (8s) are the two crossings at 1x, divided by the speed setting;
`holePoints` is the apparent shadow radius in points, `warpPoints` the reach
above, and `swirl` is what winds the desktop in.

A slow speed must not make the crossings outlast the break, so they are scaled
down to fit when they would. That means short breaks cannot honour slow speeds —
on a 20 second break, 0.25x, 0.5x and 1x all collapse to the same ~18 seconds of
crossing:

| break | speed | swallow | release | hold |
|---|---|---|---|---|
| 20 s | 0.25x | 11.5 | 6.5 | 2.0 |
| 20 s | 1.5x | 9.3 | 5.3 | 5.3 |
| 10 min | 0.25x | 56.0 | 32.0 | 512.0 |
| 10 min | 1x | 14.0 | 8.0 | 578.0 |

Cost is dominated by `dphi` in `Shaders.swift`, the geodesic step size. It scales
with impact parameter, so grazing rays step finely and far-field rays finish in a
handful. Rays that can reach the disk are additionally capped so the slab does not
alias. Measured worst case at 3024x1964 on an M3 Pro:

| base `dphi` | `maxSteps` | disk cap | ms/frame |
|---|---|---|---|
| 0.010 | 480 | — | 19.9 |
| 0.014 | 380 | — | 15.0 |
| 0.018 | 320 | — | 12.3 |
| 0.018 | 320 | `b < +3.0` → 0.030 | 18.4 |
| 0.018 | 320 | `b < +1.0` → 0.036 | 14.2 |
| **0.018** | **320** | **`b < +1.0` → 0.026** | **14.7** |

Shipping the last row — 68 fps worst case. The finer disk cap is what the thin
slab needs; without it the volume integration bands. `maxSteps` is set in `OverlayView.swift` and must be tuned alongside
`dphi`.

## Known limits

- Colour passes through raw as Display P3. This makes untouched pixels exact,
  at the cost of the disk's tone mapping using an approximate 2.2 gamma rather
  than the true sRGB curve.
- The overlay blocks input by covering every display at screen-saver level and
  taking key focus. Cmd-Tab still switches apps underneath it — this is a firm
  interruption, not a kiosk lock.
- Displays connected or disconnected mid-break are not picked up; the overlay is
  built per break.
- Each display gets its own hole, crossing in the same direction.
- The signing certificate is self-signed and local, so the app is not
  notarised and would need re-signing to run on another machine.

## Related

`../ScreenSaver` is the original build of the same renderer as a real `.saver`
screensaver, with a procedural starfield instead of your desktop.

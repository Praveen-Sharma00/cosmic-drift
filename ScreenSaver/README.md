# Black Hole screensaver

A macOS `.saver` that raytraces a Schwarzschild black hole in a Metal fragment shader:
photon paths are integrated as geodesics, so the accretion disk behind the hole is
genuinely lensed up over the shadow, and the photon ring falls out of the same
integration rather than being drawn in.

Also modelled: Keplerian orbital velocity, relativistic Doppler beaming (the
approaching side is visibly brighter), gravitational redshift, a `r^-3/4`
temperature profile driving a blackbody colour ramp, and a procedural starfield
that is lensed along with everything else.

## Install

```sh
./build.sh
```

Builds a universal (arm64 + x86_64) bundle and copies it to
`~/Library/Screen Savers/BlackHole.saver`. Then pick **Black Hole** in
System Settings → Screen Saver.

If it is already installed and selected, quit and reopen System Settings after
rebuilding so the old bundle is unloaded.

## Files

- `Shaders.swift` — the Metal source, as a string. It is compiled at load time
  because the offline `metal` compiler ships only with full Xcode, and only the
  Command Line Tools are installed here. Verified to work inside the screensaver
  sandbox.
- `BlackHoleView.swift` — `ScreenSaverView` subclass, `CAMetalLayer` backing,
  camera animation, uniforms.
- `Info.plist` — `NSPrincipalClass` is `BlackHoleView`.

## Tuning

Camera motion and quality are in `render()` in `BlackHoleView.swift`:

- `u.steps` — geodesic integration steps per ray (380). Lower is faster, but the
  photon ring loses definition.
- `maxDrawableSide` — render resolution cap (2200 px); the layer upscales to the
  display. Raise for sharper, lower for less GPU draw.
- `u.camDist` / `u.incl` / `u.azim` — orbit distance, inclination, azimuth.
  Inclination stays near the disk plane so the lensed far side arcs overhead.

Disk geometry and look are constants at the top of `Shaders.swift`
(`DISK_IN`, `DISK_OUT`, `PERIOD`).

Measured at 4.7 ms/frame at 1600x900 on an M3 Pro, so there is plenty of headroom.

# Cosmic Drift

Two macOS experiments that render a Schwarzschild black hole by integrating null
geodesics in a single Metal fragment pass. Nothing is painted on: the shadow, the
photon ring, the lensed background and the multiple images of the accretion disk
all fall out of the same integration.

## [EventHorizon](EventHorizon/) — a break timer

A menu bar app. When the work timer runs out, a black hole crosses your screen,
lensing your actual windows around itself as it passes, then hands them back.
Screen content is captured live with ScreenCaptureKit and used as the background
the geodesics land on, so it really is your desktop being bent.

Configurable interval, crossing direction, animation speed and loop. Moving the
mouse ends a break.

## [ScreenSaver](ScreenSaver/) — a real `.saver`

The same renderer as an installable macOS screensaver, against a procedural
starfield instead of your desktop.

## Building

Each directory has its own `build.sh` and README. Both need only the Xcode
Command Line Tools — the Metal shaders are compiled at load time from source,
since the offline `metal` compiler ships only with full Xcode.

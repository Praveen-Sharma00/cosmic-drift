#!/bin/bash
# Builds Event Horizon.app and copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

NAME="EventHorizon"
APP="build/Event Horizon.app"
DEPLOY="14.0"

rm -rf build
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp Info.plist "${APP}/Contents/Info.plist"
cp AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"

SRC=(main.swift AppDelegate.swift BreakController.swift OverlayView.swift ScreenCapture.swift Shaders.swift Log.swift)

archs=()
for arch in arm64 x86_64; do
  out="build/${NAME}-${arch}"
  if swiftc -O -module-name "${NAME}" -target "${arch}-apple-macos${DEPLOY}" \
      -framework AppKit -framework Metal -framework QuartzCore \
      -framework ScreenCaptureKit -framework CoreVideo -framework IOKit \
      -o "${out}" "${SRC[@]}"; then
    archs+=("${out}")
  else
    echo "skipping ${arch}"
  fi
done
[ ${#archs[@]} -gt 0 ] || { echo "build failed" >&2; exit 1; }

lipo -create "${archs[@]}" -output "${APP}/Contents/MacOS/${NAME}"
rm -f "${archs[@]}"
# A stable identity keeps the app's designated requirement constant across
# rebuilds, so macOS does not silently drop its Screen Recording grant.
# tools/make-signing-cert.sh creates it; ad hoc is the fallback.
IDENTITY="Event Horizon Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
  codesign --force --deep --sign "${IDENTITY}" "${APP}"
  STABLE_ID=1
else
  codesign --force --deep --sign - "${APP}"
  STABLE_ID=0
  echo "no stable signing identity; signing ad hoc (see tools/make-signing-cert.sh)"
fi

DEST="/Applications/Event Horizon.app"
if pkill -f "Event Horizon.app/Contents/MacOS/EventHorizon" 2>/dev/null; then sleep 1; fi
rm -rf "${DEST}"
if cp -R "${APP}" /Applications/ 2>/dev/null; then
  # Ad-hoc builds get a new code identity each time, which silently voids the
  # Screen Recording grant; clear it so macOS asks again rather than failing
  # quietly to an opaque overlay. A stable identity needs no such reset.
  if [ "${STABLE_ID}" = "0" ]; then
    tccutil reset ScreenCapture local.eventhorizon.app >/dev/null 2>&1 || true
  fi
  touch "${DEST}"
  # Leaving the staging copy behind would put two bundles with the same
  # identifier on disk, which splits the Screen Recording grant.
  LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "${LSREG}" -u "$(pwd)/${APP}" >/dev/null 2>&1 || true
  rm -rf build
  echo "installed: ${DEST}"
  if [ "${STABLE_ID}" = "0" ]; then
    echo "NOTE: grant Screen Recording again on next launch (ad hoc = new signature)."
  fi
else
  echo "could not write to /Applications; app left at ${APP}"
  echo "WARNING: two bundles with the same id would confuse macOS - install it."
fi

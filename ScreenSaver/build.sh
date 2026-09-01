#!/bin/bash
# Builds BlackHole.saver and installs it into ~/Library/Screen Savers.
set -euo pipefail

cd "$(dirname "$0")"

NAME="BlackHole"
BUNDLE="build/${NAME}.saver"
DEPLOY="13.0"

rm -rf build
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp Info.plist "${BUNDLE}/Contents/Info.plist"

archs=()
for arch in arm64 x86_64; do
  out="build/${NAME}-${arch}"
  if swiftc -O -module-name "${NAME}" \
      -target "${arch}-apple-macos${DEPLOY}" \
      -Xlinker -bundle \
      -framework ScreenSaver -framework Metal -framework QuartzCore -framework AppKit \
      -o "${out}" BlackHoleView.swift Shaders.swift 2>/dev/null; then
    archs+=("${out}")
  else
    echo "skipping ${arch} (toolchain cannot target it)"
  fi
done

if [ ${#archs[@]} -eq 0 ]; then
  echo "build failed" >&2
  exit 1
fi

lipo -create "${archs[@]}" -output "${BUNDLE}/Contents/MacOS/${NAME}"
codesign --force --deep --sign - "${BUNDLE}"

DEST="${HOME}/Library/Screen Savers"
mkdir -p "${DEST}"
rm -rf "${DEST}/${NAME}.saver"
cp -R "${BUNDLE}" "${DEST}/"

echo "installed: ${DEST}/${NAME}.saver"

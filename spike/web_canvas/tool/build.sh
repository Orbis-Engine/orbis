#!/bin/bash
# Builds the web canvas spike into build/web.
#
#   tool/build.sh [extra flutter build web flags]
#
# Filament's web release (filament.js, filament.wasm) is fetched into the
# project's shared cache, not committed: it is 2 MB of someone else's build
# output, pinned by version here. It is copied into web/filament/ (gitignored)
# because flutter build copies everything under web/ into build/web.
#
# The material is compiled with the Mac SDK's matc, the one
# packages/orbis_filament/darwin/setup.sh fetches, because a .filamat has to
# come from the same Filament release as the engine that loads it.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(git rev-parse --show-toplevel)"
FILAMENT_VERSION=v1.76.0

# The cache sits beside the checkouts (.../Orbis Project/.cache), which is one
# level up from the main checkout and two from a worktree, so look upwards.
if [ -z "${ORBIS_CACHE:-}" ]; then
  d="$REPO"
  while [ "$d" != "/" ] && [ ! -d "$d/.cache" ]; do d="$(dirname "$d")"; done
  if [ "$d" = "/" ]; then ORBIS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/orbis"; else ORBIS_CACHE="$d/.cache"; fi
fi
DIR="$ORBIS_CACHE/filament-${FILAMENT_VERSION#v}"
TGZ="$DIR/filament-$FILAMENT_VERSION-web.tgz"
if [ ! -f "$DIR/web/filament.wasm" ]; then
  mkdir -p "$DIR/web"
  if [ ! -f "$TGZ" ]; then
    echo "web_canvas: fetching Filament $FILAMENT_VERSION (web)"
    curl -fL --retry 3 -o "$TGZ" \
      "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-web.tgz"
  fi
  tar -xzf "$TGZ" -C "$DIR/web"
fi

MATC="${MATC:-$REPO/packages/orbis_filament/darwin/third_party/filament-mac/filament/bin/matc}"
if [ ! -x "$MATC" ]; then
  echo "web_canvas: no matc at $MATC; run packages/orbis_filament/darwin/setup.sh or set MATC" >&2
  exit 1
fi

mkdir -p web/filament
cp "$DIR/web/filament.js" "$DIR/web/filament.wasm" web/filament/
# WebGL2 runs Filament's OpenGL backend with ESSL 3.0 shaders: opengl, mobile.
"$MATC" -a opengl -p mobile -o web/filament/spin.filamat material/spin.mat

# The CanvasKit renderer comes from build/web rather than Google's CDN, so the
# page (and the headless capture) works offline and from localhost.
flutter build web --release --no-web-resources-cdn "$@"

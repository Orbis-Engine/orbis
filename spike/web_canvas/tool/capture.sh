#!/bin/bash
# Serves build/web on localhost and photographs it with headless Chrome:
# twice at different virtual times (it animates), once with a parameter Dart
# set (the scene message crosses). Run tool/build.sh first.
#
#   tool/capture.sh            # writes captures/*.png and a console log per shot
#
# WebGL2 comes from SwiftShader, Chrome's software GPU, so the shots do not
# depend on the machine's GPU or on a window being visible.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${PORT:-8765}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="${OUT:-captures}"
[ -f build/web/index.html ] || { echo "capture: no build/web; run tool/build.sh" >&2; exit 1; }
mkdir -p "$OUT"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory build/web >/dev/null 2>&1 &
SERVER=$!
PROFILES="$(mktemp -d)"
trap 'kill "$SERVER" 2>/dev/null || true; rm -rf "$PROFILES"' EXIT
for _ in $(seq 100); do
  curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.1
done

# shoot <name> <virtual milliseconds> <query string>
# A fresh profile per shot keeps it clear of any Chrome already running.
shoot() {
  "$CHROME" --headless=new \
    --use-angle=swiftshader --enable-unsafe-swiftshader \
    --user-data-dir="$PROFILES/$1" --no-first-run --no-default-browser-check \
    --hide-scrollbars --window-size=1280,800 \
    --enable-logging=stderr --v=0 \
    --virtual-time-budget="$2" \
    --screenshot="$OUT/$1.png" "http://127.0.0.1:$PORT/$3" >"$OUT/$1.log" 2>&1 || true
  echo "capture: $OUT/$1.png  ($(grep -c 'CONSOLE' "$OUT/$1.log" || true) console lines)"
}

shoot 1_default_3s 3000 ""
shoot 2_default_6s 6000 ""
shoot 3_dart_hue200 5000 "?hue=200&spin=2.5"

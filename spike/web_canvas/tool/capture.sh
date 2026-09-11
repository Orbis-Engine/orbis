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
#
# Headless Chrome's --screenshot mode is documented to quit on its own once
# the shot is written, but observed here not to: the process outlives its own
# PNG once virtual-time-budget elapses, with nothing left to wait for. Left
# alone that wedges every shot queued after it (macOS ships no `timeout(1)`
# to guard against it), so this polls for the PNG and gives the process a
# couple of seconds to flush and exit on its own before killing it, with a
# hard ceiling in case even the screenshot never lands.
shoot() {
  local name="$1" budget="$2" query="$3"
  "$CHROME" --headless=new \
    --use-angle=swiftshader --enable-unsafe-swiftshader \
    --user-data-dir="$PROFILES/$name" --no-first-run --no-default-browser-check \
    --hide-scrollbars --window-size=1280,800 \
    --enable-logging=stderr --v=0 \
    --virtual-time-budget="$budget" \
    --screenshot="$OUT/$name.png" "http://127.0.0.1:$PORT/$query" >"$OUT/$name.log" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ -f "$OUT/$name.png" ]; then
      sleep 2
      kill "$pid" 2>/dev/null || true
      break
    fi
    if [ "$waited" -ge 45 ]; then
      echo "capture: $name timed out with no screenshot after ${waited}s" >&2
      kill -9 "$pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" 2>/dev/null || true
  echo "capture: $OUT/$name.png  ($(grep -c 'CONSOLE' "$OUT/$name.log" || true) console lines)"
}

shoot 1_default_3s 3000 ""
shoot 2_default_6s 6000 ""
shoot 3_dart_hue200 5000 "?hue=200&spin=2.5"

#!/bin/bash
# Serves build/web and photographs an example with headless Chrome, so the
# result of a web build is a screenshot rather than a claim.
#
#   tool/capture_web.sh [example] [milliseconds]
#
# The example is chosen the way every ORBIS_* switch is on the web: in the
# query string (see lib/orbis_env_web.dart), so sweeping one is changing a URL
# rather than rebuilding.
#
# WebGL 2 comes from SwiftShader, Chrome's software rasteriser, so a shot does
# not depend on this machine's GPU or on a window being visible. Both
# --use-angle=swiftshader and --enable-unsafe-swiftshader are needed together:
# with only one, context creation fails silently and the page draws nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
EXAMPLE="${1:-Surface}"
BUDGET="${2:-8000}"
PORT="${PORT:-8811}"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="${OUT:-captures}"
[ -f build/web/index.html ] || { echo "capture: no build/web; run flutter build web" >&2; exit 1; }
[ -f build/web/orbis_renderer.wasm ] || { echo "capture: build/web has no orbis_renderer.wasm" >&2; exit 1; }
mkdir -p "$OUT"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory build/web >/dev/null 2>&1 &
SERVER=$!
PROFILE="$(mktemp -d)"
trap 'kill "$SERVER" 2>/dev/null || true; rm -rf "$PROFILE"' EXIT
for _ in $(seq 100); do
  curl -fs "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break
  sleep 0.1
done

NAME="$(echo "$EXAMPLE" | tr '[:upper:]' '[:lower:]')"
URL="http://127.0.0.1:$PORT/?ORBIS_EXAMPLE=$EXAMPLE&ORBIS_SECONDS=1.5"

# The wait below polls for the screenshot, so a shot left over from a previous
# run would end it immediately and leave a stale picture looking like a fresh
# one — which is exactly the sort of thing this script exists to prevent.
rm -f "$OUT/$NAME.png" "$OUT/$NAME.log"

# Chrome's --screenshot mode is documented to quit once the shot is written
# but observed not to, which wedges anything queued after it and macOS ships
# no timeout(1); so this backgrounds it, polls for the PNG, and kills it
# either way past a hard ceiling. Same shape as spike/web_canvas/tool/capture.sh.
"$CHROME" --headless=new \
  --use-angle=swiftshader --enable-unsafe-swiftshader \
  --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check \
  --hide-scrollbars --window-size=1280,800 \
  --enable-logging=stderr --v=0 \
  --virtual-time-budget="$BUDGET" \
  --screenshot="$OUT/$NAME.png" "$URL" >"$OUT/$NAME.log" 2>&1 &
PID=$!
WAITED=0
while kill -0 "$PID" 2>/dev/null; do
  if [ -f "$OUT/$NAME.png" ]; then
    sleep 2
    kill "$PID" 2>/dev/null || true
    break
  fi
  if [ "$WAITED" -ge 90 ]; then
    echo "capture: $NAME timed out with no screenshot after ${WAITED}s" >&2
    kill -9 "$PID" 2>/dev/null || true
    break
  fi
  sleep 1
  WAITED=$((WAITED + 1))
done
wait "$PID" 2>/dev/null || true

echo "capture: $OUT/$NAME.png"
grep -E "orbis|Filament|feature level|WebGL" "$OUT/$NAME.log" | head -20 || true

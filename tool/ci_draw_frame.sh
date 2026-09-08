#!/bin/bash
# Runs a built app until the renderer has drawn a frame, and fails if it does
# not get there.
#
# Why this exists: building the renderer proves it compiles and links, which is
# not the thing that breaks. What breaks is a Filament precondition — a
# material destroyed while a renderable still points at it, a buffer sized from
# the wrong stride — and those abort at runtime on the first frame that hits
# them, in a build that compiled perfectly.
#
# The app is run through its executable rather than `open`, so its log arrives
# on this script's stderr and the frame can be waited for by reading it. The
# renderer prints "[orbis] frame N ... -> path" when ORBIS_DUMP_FRAME says to,
# and that line is the proof: it is printed after Filament has rendered and the
# pixels have been read back, so nothing before it can have aborted.
#
# Three outcomes, deliberately distinguished:
#   0  a frame was drawn
#   1  the app died, or ran out of time with no frame  — a real failure
#   0  no Metal device on this host                    — skipped, and said so
#
# The last is separated because a runner without a GPU is a fact about the
# runner, and turning it into a red build teaches everyone to ignore the build.
set -uo pipefail

APP="${1:?usage: ci_draw_frame.sh <path to .app>}"
SECONDS_ALLOWED="${ORBIS_FRAME_TIMEOUT:-90}"

name=$(basename "$APP" .app)
binary="$APP/Contents/MacOS/$name"
[ -x "$binary" ] || { echo "no executable at $binary"; exit 1; }

: "${ORBIS_DUMP_FRAME:=30}"
export ORBIS_DUMP_FRAME

log=$(mktemp -t orbis_ci_frame)
"$binary" > "$log" 2>&1 &
app=$!

# Kill the app however this script leaves, including a timeout or a cancelled
# job. Without this the runner hangs on a Flutter window nobody will close.
trap 'kill "$app" 2>/dev/null; wait "$app" 2>/dev/null' EXIT

drew=""
for _ in $(seq "$SECONDS_ALLOWED"); do
  if grep -q '\[orbis\] frame' "$log" 2>/dev/null; then drew=yes; break; fi
  # An app that has exited is not going to draw anything, and waiting the full
  # ninety seconds to say so wastes the run and buries the reason.
  kill -0 "$app" 2>/dev/null || break
  sleep 1
done

if [ -n "$drew" ]; then
  grep '\[orbis\] frame' "$log" | head -1
  echo "renderer drew a frame"
  exit 0
fi

if ! kill -0 "$app" 2>/dev/null; then
  wait "$app"; status=$?
  # Filament calls its own panic handler and then aborts. The handler's line is
  # the diagnosis and the abort is only the symptom, so print enough of the log
  # to carry it rather than the exit status alone.
  echo "the app exited with $status before drawing a frame:"
  tail -40 "$log"
  # A host with no Metal device cannot be asked to draw, and says as much on
  # the way down. That is not this repository being broken.
  if grep -qiE 'no metal device|failed to create.*device|MTLCreateSystemDefaultDevice' "$log"; then
    echo
    echo "SKIPPED: this host has no Metal device. The build is still checked."
    exit 0
  fi
  exit 1
fi

echo "no frame after ${SECONDS_ALLOWED}s. The app is still running, so it is"
echo "hung rather than crashed — the last thing it said was:"
tail -40 "$log"
exit 1

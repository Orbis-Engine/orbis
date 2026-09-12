#!/bin/bash
# Runs a built Windows bundle until the renderer has drawn a frame, and says
# what happened. The Windows counterpart to ci_draw_frame_linux.sh, and it
# waits for the same line for the same reason -- see that script's header.
#
# Two things are different here. There is no display server to start: a
# Windows session has a desktop whether or not anybody is looking at it, so
# nothing like Xvfb is needed and the application is simply launched. And the
# "written" line comes from the plugin rather than from the renderer's
# surface: a headless swap chain has no buffer to write out, so
# packages/orbis_filament/windows/orbis_viewport.cpp writes the picture from
# the pixels it has already read back, in the shape OrbisSurfaceApple.mm
# prints.
#
# Not a gate, and called from a step that tolerates its failure. GitHub's
# windows-latest runners have no GPU: there is no Vulkan driver, and the
# OpenGL they expose is a software path that has never been checked against
# the standard surface's feature level. So the expected outcome there is
# "the renderer would not start", reported rather than failed on, exactly as
# the iOS simulator job reports rather than fails. The build is the gate.
#
# Three outcomes, as the macOS and Linux scripts distinguish them:
#   0  a frame was drawn
#   1  the application died, or ran out of time with no frame — a real failure
#   0  no GL or Vulkan on this host at all                    — skipped, said so
set -uo pipefail

BUNDLE="${1:?usage: ci_draw_frame_windows.sh <path to the Runner directory>}"
SECONDS_ALLOWED="${ORBIS_FRAME_TIMEOUT:-120}"
BINARY="$BUNDLE/orbis_gallery.exe"
[ -x "$BINARY" ] || [ -f "$BINARY" ] || { echo "no executable at $BINARY"; exit 1; }

: "${ORBIS_DUMP_FRAME:=30}"
export ORBIS_DUMP_FRAME

log=$(mktemp -t orbis_ci_frame.XXXXXX)
"$BINARY" > "$log" 2>&1 &
app=$!

trap 'kill "$app" 2>/dev/null; wait "$app" 2>/dev/null' EXIT

drew=""
for _ in $(seq "$SECONDS_ALLOWED"); do
  if grep -q '\[orbis\] frame .* -> .*: written' "$log" 2>/dev/null; then
    drew=yes
    break
  fi
  kill -0 "$app" 2>/dev/null || break
  sleep 1
done

if [ -n "$drew" ]; then
  # Both lines: the renderer's own, saying what the frame cost, and the
  # plugin's, saying where the picture went.
  grep '\[orbis\] frame' "$log" | head -2
  echo "renderer drew a frame"
  exit 0
fi

if ! kill -0 "$app" 2>/dev/null; then
  wait "$app"; status=$?
  echo "the application exited with $status before drawing a frame:"
  tail -40 "$log"
  if grep -qiE 'no backend|vulkan.*no driver|could not start|failed to create.*(context|device|display)' "$log"; then
    echo
    echo "SKIPPED: this host has no usable GL or Vulkan. The build is still checked."
    exit 0
  fi
  exit 1
fi

echo "no frame after ${SECONDS_ALLOWED}s. The application is still running, so"
echo "it is hung rather than crashed — the last thing it said was:"
tail -40 "$log"
exit 1

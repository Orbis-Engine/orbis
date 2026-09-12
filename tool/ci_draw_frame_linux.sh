#!/bin/bash
# Runs a built Linux bundle until the renderer has drawn a frame, and fails if
# it does not get there. The Linux counterpart to ci_draw_frame.sh, and it
# waits for the same line for the same reason -- see that script's header.
#
# Two things are different here. A Linux Flutter application needs a display
# even to draw into a texture nobody sees: the GTK embedder creates its GL
# contexts against one, so with no DISPLAY the application exits before the
# engine starts. Xvfb is started here when there is none. And the "written"
# line comes from the plugin rather than from the renderer's surface: a
# headless swap chain has no buffer to write out, so
# packages/orbis_filament/linux/orbis_viewport.cc writes the picture from the
# pixels it has already read back, in the shape OrbisSurfaceApple.mm prints.
#
# Three outcomes, as the macOS script distinguishes them:
#   0  a frame was drawn
#   1  the application died, or ran out of time with no frame — a real failure
#   0  no GL or Vulkan on this host at all                    — skipped, said so
set -uo pipefail

BUNDLE="${1:?usage: ci_draw_frame_linux.sh <path to the bundle directory>}"
SECONDS_ALLOWED="${ORBIS_FRAME_TIMEOUT:-120}"
BINARY="$BUNDLE/orbis_gallery"
[ -x "$BINARY" ] || { echo "no executable at $BINARY"; exit 1; }

: "${ORBIS_DUMP_FRAME:=30}"
export ORBIS_DUMP_FRAME

# A software rasteriser unless the host has something better. Both are named
# because Filament asks for Vulkan first and falls back to OpenGL, and which
# one answers decides which of these two matters.
export LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}"

xvfb=""
if [ -z "${DISPLAY:-}" ]; then
  Xvfb :99 -screen 0 1280x720x24 > /dev/null 2>&1 &
  xvfb=$!
  export DISPLAY=:99
  # Waited for rather than slept past: an application that starts before the
  # server is listening fails with a connection error that looks nothing like
  # the real problem.
  for _ in $(seq 50); do
    xdpyinfo -display :99 > /dev/null 2>&1 && break
    sleep 0.2
  done
fi

log=$(mktemp -t orbis_ci_frame.XXXXXX)
"$BINARY" > "$log" 2>&1 &
app=$!

trap 'kill "$app" 2>/dev/null; wait "$app" 2>/dev/null;
      [ -n "$xvfb" ] && kill "$xvfb" 2>/dev/null' EXIT

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
  if grep -qiE 'no backend|vulkan.*no driver|could not start|failed to create.*(context|display)' "$log"; then
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

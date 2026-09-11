#!/bin/bash
# Runs a built simulator app until the renderer has drawn a frame, and fails if
# it does not get there for a reason we do not already know about.
#
# The iOS twin of ci_draw_frame.sh, and it exists for the same reason: building
# the renderer proves it compiles and links, which is not the thing that breaks.
# What breaks is a Filament precondition — a material the device will not take,
# a buffer sized from the wrong stride — and those abort on the first frame that
# hits them, in a build that compiled perfectly.
#
# Everything differs from the macOS script in mechanism and nothing in intent.
# A simulator app is not an executable this script can start: it is installed
# into a device container and launched by simctl, its environment is passed
# through SIMCTL_CHILD_-prefixed variables, and its stdout arrives only because
# --console-pty attaches one.
#
# Four outcomes, deliberately distinguished:
#   0  a frame was drawn
#   0  the run hit the known feature-level limit                 — see below
#   0  no simulator runtime on this host             — skipped, and said so
#   1  anything else: the app died, or ran out of time with no frame
#
# The second is the one to explain. The standard lit surface declares Filament
# feature level 3, because matc allows a material nine samplers below that and
# the surface binds twelve. Filament's Metal backend reports level 3 only for
# MTLGPUFamilyApple6 or newer — A13, so an iPhone 11 and later — and the
# simulator's virtual GPU reports MTLGPUFamilyApple2, so it gets level 2 and
# refuses the material. That is a fact about the simulator's GPU and not about
# this repository, so it is reported loudly and not turned into a red build;
# the same reasoning as the macOS script's "no Metal device" skip. When the
# surface reaches feature level 2 this branch simply stops being taken and the
# frame above is what the job checks, with no change here.
set -uo pipefail

APP="${1:?usage: ci_draw_frame_ios.sh <path to .app>}"
SECONDS_ALLOWED="${ORBIS_FRAME_TIMEOUT:-90}"
DEVICE="${ORBIS_SIM_DEVICE:-iPhone 16}"

[ -d "$APP" ] || { echo "no app bundle at $APP"; exit 1; }

bundle=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")
[ -n "$bundle" ] || { echo "no CFBundleIdentifier in $APP"; exit 1; }

# Whatever is already booted, else the newest runtime's copy of the named
# device. Reusing a booted one keeps this usable on a developer's machine,
# where booting a second simulator is slow and pointless.
udid=$(xcrun simctl list devices booted -j 2>/dev/null \
  | /usr/bin/python3 -c 'import json,sys
d=json.load(sys.stdin)["devices"]
print(next((x["udid"] for v in d.values() for x in v if x.get("state")=="Booted"), ""))')

if [ -z "$udid" ]; then
  udid=$(xcrun simctl list devices available -j 2>/dev/null \
    | ORBIS_SIM_DEVICE="$DEVICE" /usr/bin/python3 -c 'import json,os,sys
want=os.environ["ORBIS_SIM_DEVICE"]
d=json.load(sys.stdin)["devices"]
# Newest runtime first, so a host with several picks the one most like a
# current device rather than whichever the dictionary happened to order first.
runtimes=sorted((k for k in d if "iOS" in k), reverse=True)
for r in runtimes:
    for x in d[r]:
        if x.get("isAvailable") and want in x["name"]:
            print(x["udid"]); sys.exit()
for r in runtimes:
    for x in d[r]:
        if x.get("isAvailable") and "iPhone" in x["name"]:
            print(x["udid"]); sys.exit()')
  if [ -z "$udid" ]; then
    echo "SKIPPED: this host has no iOS simulator to run on. The build is"
    echo "still checked."
    exit 0
  fi
  echo "booting $udid"
  xcrun simctl boot "$udid" || { echo "the simulator would not boot"; exit 1; }
  # Booted is not the same as ready: simctl returns as soon as the device is
  # launching, and installing into one that has not finished comes back with
  # "Unable to lookup in current state".
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
fi

xcrun simctl install "$udid" "$APP" || { echo "the app would not install"; exit 1; }

: "${ORBIS_DUMP_FRAME:=30}"
export ORBIS_DUMP_FRAME
# Every ORBIS_ switch, not only the frame to dump. simctl hands an app only the
# variables prefixed SIMCTL_CHILD_, so a switch left unprefixed does nothing at
# all — ORBIS_EXAMPLE=Decals would quietly draw the first example instead, which
# is what made the simulator look as if it could only draw a placeholder.
while IFS='=' read -r name value; do
  case "$name" in
    ORBIS_*) export "SIMCTL_CHILD_$name=$value" ;;
  esac
done < <(env)

log=$(mktemp -t orbis_ci_frame_ios)
# --console-pty rather than --console: without a pty the app's stdout is fully
# buffered and nothing arrives until it exits, which for an app that is meant
# to keep running means nothing arrives at all.
xcrun simctl launch --console-pty "$udid" "$bundle" > "$log" 2>&1 &
launcher=$!

trap 'kill "$launcher" 2>/dev/null; xcrun simctl terminate "$udid" "$bundle" 2>/dev/null' EXIT

drew=""
refused=""
for _ in $(seq "$SECONDS_ALLOWED"); do
  # The line that ends in "written", for the same reason the macOS script waits
  # for it: the renderer prints the frame's cost first and the picture only
  # after it has been read back.
  if grep -q '\[orbis\] frame .* -> .*: written' "$log" 2>/dev/null; then
    drew=yes
    break
  fi
  if grep -q 'has feature level 3 which is not supported' "$log" 2>/dev/null; then
    refused=yes
    break
  fi
  sleep 1
done

if [ -n "$drew" ]; then
  grep '\[orbis\] frame' "$log" | head -2
  echo "renderer drew a frame on the simulator"
  exit 0
fi

if [ -n "$refused" ]; then
  grep -E 'Backend feature level|feature level 3 which is not supported' "$log" | head -2
  echo
  echo "KNOWN: the simulator's GPU is below the standard surface's feature"
  echo "level, so no frame can be drawn here. The build and the engine are"
  echo "still checked. See the header of this script."
  exit 0
fi

echo "no frame after ${SECONDS_ALLOWED}s. The last thing the app said was:"
tail -40 "$log"
exit 1

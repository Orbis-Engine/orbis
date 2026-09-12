#!/bin/bash
# Runs orbis_input's tests on Linux, against a gamepad the kernel invents.
#
# There is no controller attached to the machine this was developed on and no
# Steam Deck, so the read path is exercised the only honest way available:
# `/dev/uinput` is asked to create an event device with a pad's buttons, axes
# and ranges, and the backend opens and reads it exactly as it would hardware.
# What that proves and what it does not is in packages/orbis_input/README.md.
#
# Two things about containers are worth knowing, because both cost a while to
# work out and neither announces itself:
#
#   1. A container's /dev is a tmpfs. uinput creates the device — it appears
#      under /sys/class/input straight away — but no node is ever made for it,
#      because devtmpfs is what makes nodes and it is not mounted there. So
#      this mounts a real devtmpfs at /devfs and points the tests at
#      /devfs/input through ORBIS_INPUT_DEV. The failure without it is a pad
#      that sysfs can see and nothing can open.
#
#   2. Writing /dev/uinput needs more than the node being passed in with
#      --device: mounting devtmpfs needs CAP_SYS_ADMIN, so this runs
#      --privileged. On a real Linux host neither applies — the tests run
#      directly, needing only membership of a group that can write uinput.
#
# The image needs a Dart SDK and nothing else: this package is pure Dart and
# `dart:ffi` straight to libc, so there is no Flutter, no Filament and no GPU
# in the way. The Linux container from tool/linux_container/Dockerfile works
# too and already carries a Dart — name it in ORBIS_INPUT_IMAGE.
#
#   ./tool/check_input_linux.sh
#   ORBIS_INPUT_IMAGE=orbis-linux:trixie ./tool/check_input_linux.sh
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE="${ORBIS_INPUT_IMAGE:-dart:stable}"

# On a Linux host with uinput there is no reason to start a container at all.
if [ "$(uname -s)" = "Linux" ] && [ -w /dev/uinput ]; then
  echo "== orbis_input on this host =="
  cd packages/orbis_input || exit 1
  dart pub get > /dev/null 2>&1
  dart analyze && dart test
  exit $?
fi

if ! command -v docker > /dev/null; then
  echo "no docker, and this host cannot write /dev/uinput."
  echo "SKIPPED: the parsing and mapping tests still run under tool/check.sh;"
  echo "only the end-to-end ones need a uinput device."
  exit 0
fi

echo "== orbis_input in $IMAGE =="
docker run --rm --privileged \
  -v "$PWD:/work" -w /work/packages/orbis_input \
  -e ORBIS_INPUT_DEV=/devfs/input \
  "$IMAGE" bash -c '
    set -e
    # The real device filesystem, because the container /dev is a tmpfs that
    # nothing will ever create a node in.
    mkdir -p /devfs && mount -t devtmpfs devtmpfs /devfs
    test -e /dev/uinput || { echo "no /dev/uinput in this kernel"; exit 3; }
    dart pub get > /dev/null
    dart analyze
    dart test
  '
status=$?

if [ "$status" -eq 3 ]; then
  echo
  echo "SKIPPED: this kernel has no uinput, so no virtual pad can be made."
  exit 0
fi
exit "$status"

#!/bin/bash
# Analyzes and tests everything in this repository that does not need a window.
#
# The renderer is excluded on purpose: it needs Flutter, a macOS host and a
# Filament download, and it is checked by building it. Networking, scripting
# and the examples live in their own repositories and check themselves.
set -uo pipefail
cd "$(dirname "$0")/.."

# Every package Dart alone can build. Adding a package to the repository does
# not add it here, which is how four of them went a long while with three
# hundred tests nobody was running. What is on disk is checked against this
# below rather than trusted.
PACKAGES=(
  packages/orbis_agent
  packages/orbis_camera
  packages/orbis_collide
  packages/orbis_codegen
  packages/orbis_core
  packages/orbis_effect
  packages/orbis_input
  packages/orbis_light
  packages/orbis_mesh
  packages/orbis_native
  packages/orbis_noise
  packages/orbis_rig
  packages/orbis_sequence
  packages/orbis_sprite
  packages/orbis_weather
)

failures=0

# A package needing Flutter is checked by tool/check_flutter.sh, one needing
# neither is checked here, and a package in no list at all is checked by
# nothing. That last case is the one worth saying out loud: it looks exactly
# like a passing build.
listed_elsewhere=$(grep -oE 'packages/orbis_[a-z_]+' tool/check_flutter.sh 2>/dev/null | sort -u)
for found in packages/*/; do
  name=${found%/}
  # No pubspec is not a package. Moving a package to its own repository leaves
  # the directory behind with a lock file in it, and that residue is not
  # something to report as unchecked.
  [ -f "$name/pubspec.yaml" ] || continue
  case " ${PACKAGES[*]} " in *" $name "*) continue ;; esac
  case "$listed_elsewhere" in *"$name"*) continue ;; esac
  echo "  note  $name is checked by nothing"
done

echo "== native =="
if ./tool/check_native.sh > /tmp/orbis_native.log 2>&1; then
  echo "  ok    core C++ checks"
else
  echo "  FAIL  core C++ checks"; tail -20 /tmp/orbis_native.log; failures=$((failures+1))
fi

for package in "${PACKAGES[@]}"; do
  echo "== $package =="
  (cd "$package" && dart pub get > /dev/null 2>&1)

  if (cd "$package" && dart analyze > /tmp/orbis_analyze.log 2>&1); then
    echo "  ok    analyze"
  else
    echo "  FAIL  analyze"; tail -20 /tmp/orbis_analyze.log; failures=$((failures+1))
  fi

  if (cd "$package" && dart test > /tmp/orbis_test.log 2>&1); then
    # The reporter redraws one line with carriage returns and colour, so the
    # summary is the last of those, stripped.
    summary=$(tr '\r' '\n' < /tmp/orbis_test.log | tail -1 \
      | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[0-9:]* //')
    echo "  ok    $summary"
  else
    echo "  FAIL  tests"; tail -25 /tmp/orbis_test.log; failures=$((failures+1))
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "everything green"
else
  echo "$failures failing step(s)"
fi
exit "$failures"

#!/bin/bash
# Analyzes and tests the packages that need Flutter but not a GPU.
#
# Separate from tool/check.sh because the two need different toolchains: these
# resolve against the Flutter SDK and run under flutter_test, so a machine with
# only the Dart SDK can still run everything else. Nothing here draws — the
# renderer's tests check the buffers and the bindings it builds, not the
# picture, which is what makes them runnable on a headless Linux box.
#
# Building the renderer's native side is a separate matter again; that needs a
# macOS host and an application to build, and CI does it by building the
# viewport example.
set -uo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(
  packages/orbis_examples
  packages/orbis_filament
  packages/orbis_ui
)

failures=0

for package in "${PACKAGES[@]}"; do
  echo "== $package =="
  (cd "$package" && flutter pub get > /dev/null 2>&1)

  if (cd "$package" && flutter analyze > /tmp/orbis_flutter_analyze.log 2>&1); then
    echo "  ok    analyze"
  else
    echo "  FAIL  analyze"; tail -20 /tmp/orbis_flutter_analyze.log; failures=$((failures+1))
  fi

  # A package can legitimately have nothing to run — orbis_examples is scenes
  # to be drawn, and its checking is that it analyzes and that the apps which
  # show it build. Skipped rather than failed, but said out loud, so an
  # emptied test directory does not read as a passing suite.
  if [ ! -d "$package/test" ]; then
    echo "  --    no tests"
    continue
  fi

  if (cd "$package" && flutter test > /tmp/orbis_flutter_test.log 2>&1); then
    summary=$(tr '\r' '\n' < /tmp/orbis_flutter_test.log | tail -1 \
      | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[0-9:]* //')
    echo "  ok    $summary"
  else
    echo "  FAIL  tests"; tail -25 /tmp/orbis_flutter_test.log; failures=$((failures+1))
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "everything green"
else
  echo "$failures failing step(s)"
fi
exit "$failures"

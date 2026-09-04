#!/bin/bash
# Analyzes and tests everything that does not need a window.
#
# The renderer is excluded on purpose: it needs Flutter, a macOS host and a
# Filament download, and it has its own proof. Everything here runs anywhere
# Dart and a C++ compiler do.
set -uo pipefail
cd "$(dirname "$0")/.."

PACKAGES=(
  packages/orbis_core
  packages/orbis_net
  packages/orbis_net_dashwire
  examples/simulation
)

failures=0

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
    echo "  ok    $(tail -1 /tmp/orbis_test.log | sed 's/^[0-9:]* //')"
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

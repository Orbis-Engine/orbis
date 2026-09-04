#!/bin/bash
# Formats the repository, or checks it with --check.
#
# Generated files are excluded: the emitter's output is not what the formatter
# would produce, so formatting it would be undone by the next generation and
# every regeneration would show as a diff.
set -uo pipefail
cd "$(dirname "$0")/.."

# find | xargs rather than an array, so this runs on the bash macOS ships as
# well as the one Linux does.
sources() {
  find packages -name '*.dart' \
    -not -name '*.g.dart' \
    -not -path '*/.dart_tool/*' \
    -not -path '*/build/*' \
    -not -path '*/quickjs-ng/*' -print0
}

if [ "${1:-}" = "--check" ]; then
  sources | xargs -0 dart format --output=none --set-exit-if-changed
else
  sources | xargs -0 dart format
fi

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

# The formatter reads each package's language version out of its resolved
# .dart_tool/package_config.json, and formats differently without it — the
# newer line-splitting style is gated on that version. So an unresolved
# checkout disagrees with a resolved one about what "formatted" means, which
# is why this check passed on a developer's machine and failed on CI for
# weeks with no version difference between them.
#
# Resolving is what makes the two agree. Only packages that need it, so this
# costs nothing once a checkout is warm.
for package in packages/*/; do
  [ -f "$package/pubspec.yaml" ] || continue
  [ -f "$package/.dart_tool/package_config.json" ] && continue
  if grep -q '^  flutter:' "$package/pubspec.yaml" && command -v flutter > /dev/null; then
    (cd "$package" && flutter pub get > /dev/null 2>&1)
  else
    (cd "$package" && dart pub get > /dev/null 2>&1)
  fi
done

if [ "${1:-}" = "--check" ]; then
  sources | xargs -0 dart format --output=none --set-exit-if-changed
else
  sources | xargs -0 dart format
fi

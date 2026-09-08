#!/bin/bash
# Requires a version bump and a changelog line for every package whose library
# code changed on this branch.
#
# The rule is in VERSIONING.md; this is what stops it depending on somebody
# remembering it at five o'clock. It is deliberately narrow: only files under
# a package's lib/ count, so a branch that fixes a test, a comment, a workflow
# or a page of documentation is not asked to invent a release.
#
# A branch whose library changes are genuinely not a feature — a reformat, a
# rename with no behaviour in it — says so with a `Version-exempt: <reason>`
# line in one of its commit messages, and this honours it and prints it.
#
# Usage: check_versions.sh [base ref]   (default: origin/master, else master)
set -uo pipefail
cd "$(dirname "$0")/.."

BASE="${1:-}"
if [ -z "$BASE" ]; then
  if git rev-parse --verify --quiet origin/master > /dev/null; then
    BASE=origin/master
  else
    BASE=master
  fi
fi

if ! git rev-parse --verify --quiet "$BASE" > /dev/null; then
  echo "no such ref: $BASE"
  exit 1
fi

# The merge base, not the tip: comparing against a master that has moved on
# would demand a bump for somebody else's changes.
MERGE_BASE=$(git merge-base "$BASE" HEAD) || exit 1

if [ "$MERGE_BASE" = "$(git rev-parse HEAD)" ]; then
  echo "nothing on this branch that is not already on $BASE"
  exit 0
fi

version_at() {
  # $1 ref, $2 package. Empty when the package did not exist there, which is
  # a new package and needs no bump.
  git show "$1:packages/$2/pubspec.yaml" 2>/dev/null \
    | sed -n 's/^version: *//p' | head -1
}

# An escape hatch, because the check cannot tell a reflow from a rewrite.
# `dart format` joining two lines is not a feature, and git cannot see that:
# --ignore-all-space compares within lines and a reflow changes how many there
# are. Rather than guess, the exemption is stated in a commit and printed
# here, so the exception is in the history next to the reason for it.
# The trailer names the packages it covers, and only those:
#
#   Version-exempt: orbis_camera orbis_light - dart format only
#   Version-exempt: all - repository-wide reformat
#
# Naming them matters. A branch-wide exemption exempts everything committed
# after it too, so a reformat early on quietly excuses the feature that lands
# later — which is the failure this check exists to prevent, reintroduced by
# the escape hatch meant to make it usable.
exempt=$(git log --format='%B' "$MERGE_BASE"..HEAD \
  | sed -n 's/^Version-exempt: *//p' \
  | sed 's/[-—:].*//' | tr ' ' '\n' | grep -v '^$' | sort -u)

changed=$(git diff --name-only "$MERGE_BASE"...HEAD -- 'packages/*/lib/*' \
  | cut -d/ -f2 | sort -u)

if [ -z "$changed" ]; then
  echo "no package library code changed — no version bump needed"
  exit 0
fi

failures=0
for package in $changed; do
  case "$exempt" in
    *all*) echo "  --    $package exempted"; continue ;;
  esac
  if echo "$exempt" | grep -qx "$package"; then
    echo "  --    $package exempted"
    continue
  fi

  was=$(version_at "$MERGE_BASE" "$package")
  now=$(version_at HEAD "$package")

  if [ -z "$was" ]; then
    echo "  ok    $package is new at $now"
    continue
  fi

  if [ "$was" = "$now" ]; then
    echo "  FAIL  $package: lib/ changed but version is still $now"
    echo "        Bump it in packages/$package/pubspec.yaml and add a line to"
    echo "        packages/$package/CHANGELOG.md. See VERSIONING.md."
    failures=$((failures + 1))
    continue
  fi

  # A bump nobody wrote down is half the rule. The changelog is the half a
  # consumer actually reads.
  if ! grep -qF "$now" "packages/$package/CHANGELOG.md" 2>/dev/null; then
    echo "  FAIL  $package: version is $now but CHANGELOG.md does not mention it"
    failures=$((failures + 1))
    continue
  fi

  echo "  ok    $package $was -> $now"
done

echo
if [ "$failures" -eq 0 ]; then
  echo "every changed package is versioned"
else
  echo "$failures package(s) need a version bump"
fi
exit "$failures"

#!/usr/bin/env bash
#
# Stages everything the Android plugin needs that is too big, too generated or
# too machine-specific to commit -- the Android-shaped counterpart to
# ../darwin/setup.sh, which this deliberately mirrors wherever the two
# platforms want the same thing done.
#
#   1. third_party/filament
#        A symlink to Filament 1.76.0's unpacked Android release: headers once,
#        static libraries for all four ABIs. Nothing is copied.
#
#   2. ../darwin/orbis_filament/Sources/orbis_filament_native/generated/*.h
#        The renderer's materials, compiled by the *host* matc (an x86_64/
#        arm64 macOS binary -- there is no Android build of it) for the
#        `opengl` and `vulkan` backends, and the SMAA/LTC lookup tables the
#        renderer also expects there. Written into the *same* generated/
#        directory darwin/setup.sh writes Metal's materials into, and that is
#        deliberate, not a shortcut: OrbisRendererCore.cpp is one file
#        compiled for every platform, its `#include "generated/foo.h"` lines
#        are unconditional, and C++'s quote-include rule always resolves a
#        relative include against the *including file's own directory*
#        first -- before any -I flag a platform's build could add. So there
#        is exactly one directory either platform's materials can live in for
#        that file to find them, and sharing it is the only way both
#        platforms can build from the one source file unmodified.
#
#        This is safe because darwin/setup.sh already stamps what it built
#        the materials with (SDK version and matc flags, in generated/.matc)
#        and recompiles everything whenever that stamp does not match what it
#        is about to build -- which is exactly "the other platform's setup.sh
#        ran more recently". The cost is a re-compile (a few seconds; matc is
#        fast) the first time you switch which platform you are building
#        after touching the other; the materials are never stale. Every
#        Android build here re-runs this script first (see the Gradle
#        wiring in ../build.gradle.kts) for the same reason darwin's
#        prepare_command re-runs its own: so this is automatic rather than a
#        step somebody has to remember.
#
# Re-running is cheap and idempotent. Run it after a fresh clone and any time
# a .mat file changes.
set -euo pipefail
cd "$(dirname "$0")"

FILAMENT_VERSION="v1.76.0"

# packages/orbis_filament/android -> packages/orbis_filament -> packages ->
# worktree root -> .worktrees -> the project root .cache/ sits beside.
here="$(pwd)"
worktree_root="$(cd "$here/../../.." && pwd)"
project_root="$(cd "$worktree_root/../.." && pwd)"

# Overridable for a checkout laid out differently (CI included), but the
# default matches where this was proven on the dev machine: unpacked once,
# reused by every worktree rather than fetched per checkout.
FILAMENT_ANDROID_DIR="${ORBIS_FILAMENT_ANDROID_DIR:-$project_root/.cache/filament-1.76.0/android-native/filament}"

SDK_DIR="third_party"
FILAMENT="$SDK_DIR/filament"
DARWIN_NATIVE="../darwin/orbis_filament/Sources/orbis_filament_native"
GENERATED="$DARWIN_NATIVE/generated"

fail() { echo "orbis_filament/android/setup.sh: $*" >&2; exit 1; }

# matc is a host tool -- it compiles materials on whatever machine runs this
# script, not on the target (Android) -- so which one is right depends on
# the host, not on anything Android-specific. On macOS this is the same
# binary darwin/setup.sh already fetches for its own build, reused rather
# than fetched twice. Elsewhere (a Linux CI runner, chiefly, which is the
# only other host this has been exercised on) there is no darwin checkout to
# borrow it from, so a Linux Filament release is fetched for its matc alone;
# everything else in that release (the libraries) is unused here.
case "$(uname -s)" in
  Darwin)
    MATC="../darwin/third_party/filament-mac/filament/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC (run ../darwin/setup.sh first --" \
      "it is a host tool, built once for whichever Mac runs this, and every" \
      "platform's materials are compiled with the same binary)"
    ;;
  Linux)
    MATC_DIR="${ORBIS_FILAMENT_MATC_DIR:-$project_root/.cache/filament-1.76.0/linux}"
    if [ ! -x "$MATC_DIR/filament/bin/matc" ]; then
      echo "orbis_filament/android: fetching Filament $FILAMENT_VERSION (linux, for its matc)"
      mkdir -p "$SDK_DIR/linux-matc"
      curl -fsSL -o "$SDK_DIR/linux-matc/filament.tgz" \
        "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-linux.tgz"
      tar xzf "$SDK_DIR/linux-matc/filament.tgz" -C "$SDK_DIR/linux-matc"
      rm -f "$SDK_DIR/linux-matc/filament.tgz"
      MATC_DIR="$SDK_DIR/linux-matc"
    fi
    MATC="$MATC_DIR/filament/bin/matc"
    [ -x "$MATC" ] || fail "no matc at $MATC even after fetching"
    ;;
  *)
    fail "no matc for host $(uname -s); add a case for it above"
    ;;
esac

# 1. The Android release. Symlinked from the local cache if it is there
#    (true on this dev machine and every worktree beside it); otherwise
#    fetched the same way darwin/setup.sh fetches the mac and iOS releases,
#    for a checkout -- CI, chiefly -- that has no pre-populated cache.
mkdir -p "$SDK_DIR"
if [ -d "$FILAMENT_ANDROID_DIR/include" ]; then
  ln -sfn "$FILAMENT_ANDROID_DIR" "$FILAMENT"
  echo "orbis_filament/android: third_party/filament -> $FILAMENT_ANDROID_DIR"
elif [ -d "$FILAMENT/include" ]; then
  echo "orbis_filament/android: Filament $FILAMENT_VERSION (android) already present"
else
  echo "orbis_filament/android: fetching Filament $FILAMENT_VERSION (android)"
  echo "  (unverified path -- this asset name has not been exercised; if it" \
       "404s, unpack a release by hand into \$ORBIS_FILAMENT_ANDROID_DIR)"
  mkdir -p "$SDK_DIR/android-fetched"
  curl -fsSL -o "$SDK_DIR/android-fetched/filament.tgz" \
    "https://github.com/google/filament/releases/download/$FILAMENT_VERSION/filament-$FILAMENT_VERSION-android.tgz"
  tar xzf "$SDK_DIR/android-fetched/filament.tgz" -C "$SDK_DIR/android-fetched"
  rm -f "$SDK_DIR/android-fetched/filament.tgz"
  rm -f "$FILAMENT"
  ln -sfn "android-fetched/filament" "$FILAMENT"
fi
[ -d "$FILAMENT/lib/arm64-v8a" ] || fail "no arm64-v8a libs at $FILAMENT/lib"
# matc itself was already resolved and checked above, per host.

# 2. The SMAA and LTC tables. Not backend-specific -- precomputed constant
#    data, the same bytes on every platform -- so they are safe to share
#    unconditionally, unlike the materials below. Skipped if darwin/setup.sh
#    (or a previous run of this script) already fetched them.
mkdir -p "$GENERATED"
SMAA_FROM="https://raw.githubusercontent.com/iryoku/smaa/master/Textures"
for tex in AreaTex SearchTex; do
  if [ ! -s "$GENERATED/$tex.h" ]; then
    echo "orbis_filament/android: fetching SMAA $tex"
    curl -fsSL -o "$GENERATED/$tex.h" "$SMAA_FROM/$tex.h"
  fi
done
LTC_HEADER="$GENERATED/LtcTables.h"
if [ ! -s "$LTC_HEADER" ]; then
  echo "orbis_filament/android: fetching the LTC tables"
  LTC_FROM="https://raw.githubusercontent.com/selfshadow/ltc_code/master/fit/results/ltc.js"
  curl -fsSL -o /tmp/orbis_ltc_android.js "$LTC_FROM"
  {
    echo "// Generated by setup.sh from $LTC_FROM"
    echo "// Heitz, Dupuy, Hill and Neubelt (SIGGRAPH 2016)."
    echo "// See LICENSES/LTC.txt. Do not edit."
    slice() {
      echo "static const float $2[] = {"
      awk -v want="$1" '
        index($0, "var " want " = [") { on = 1; sub(/.*\[/, ""); }
        !on { next }
        { line = $0 }
        index(line, "];") { sub(/\];.*/, "", line); print line; exit }
        { print line }
      ' /tmp/orbis_ltc_android.js
      echo "};"
    }
    slice g_ltc_1 kLtcMatrix
    slice g_ltc_2 kLtcFresnel
  } > "$LTC_HEADER"
  rm -f /tmp/orbis_ltc_android.js
fi

# 3. The materials themselves -- opengl and vulkan, mobile shader variants
#    only (Android is always a mobile-class GPU, so there is no desktop
#    variant to also pay for the way darwin's `-p all` does for its own
#    reason of serving macOS and iOS from one build).
ORBIS_MATC_BACKENDS="${ORBIS_MATC_BACKENDS:-opengl vulkan}"
MATC_API=""
for api in ${ORBIS_MATC_BACKENDS//,/ }; do
  case "$api" in
    metal|vulkan|opengl|all) MATC_API="$MATC_API -a $api" ;;
    *)
      fail "ORBIS_MATC_BACKENDS names '$api', which is not one of metal, " \
        "vulkan, opengl or all."
      ;;
  esac
done
MATC_PROFILE="${ORBIS_MATC_PROFILE:-mobile}"
MATC_FLAGS="${MATC_API# } -p $MATC_PROFILE"
MATC_STAMP="$GENERATED/.matc"
MATC_WANT="$FILAMENT_VERSION android $MATC_FLAGS"
STALE=""
if [ "$(cat "$MATC_STAMP" 2>/dev/null || true)" != "$MATC_WANT" ]; then
  STALE=1
fi

BLENDS="opaque transparent fade masked add"
# lit_slim is the nine-sampler surface orbis::Renderer chooses instead of lit
# below Filament's third feature level (see PORTING.md) -- its own five
# packages, not a variant of lit's, mirroring darwin/setup.sh exactly.
VARIANTS="lit lit_slim unlit video"

compile() {
  local source="$1" name="$2" blend="${3:-}"
  local header="$GENERATED/${name}_material.h"
  if [ -z "$STALE" ] && [ -f "$header" ] && [ ! "$source" -nt "$header" ]; then
    return
  fi
  echo "orbis_filament/android: compiling $name"
  local input="$source"
  if [ -n "$blend" ]; then
    input="/tmp/orbis_android_src_$name.mat"
    sed "s/^\( *blending *: *\)[a-z]*,/\1$blend,/" "$source" > "$input"
  fi
  # shellcheck disable=SC2086 -- the flags are ours and are meant to split.
  "$MATC" $MATC_FLAGS -o "/tmp/orbis_android_$name.filamat" "$input"
  (cd /tmp && xxd -i "orbis_android_$name.filamat") \
    | sed "s/orbis_android_${name}_filamat/k${name}Material/g" > "$header"
  rm -f "/tmp/orbis_android_$name.filamat" "/tmp/orbis_android_src_$name.mat"
}

for mat in ../darwin/materials/*.mat; do
  name="$(basename "$mat" .mat)"
  case " $VARIANTS " in
    *" $name "*)
      for blend in $BLENDS; do
        compile "$mat" "${name}_${blend}" "$blend"
      done
      ;;
    *)
      compile "$mat" "$name"
      ;;
  esac
done

echo "$MATC_WANT" > "$MATC_STAMP"
echo "orbis_filament/android: setup complete"
